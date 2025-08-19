;; ------------------------------------------------------------
;; Contract: Greenproof
;; Description: Reward-based recycling verification system on Stacks
;; Author: Thankgod Isaac + ChatGPT
;; License: MIT
;; ------------------------------------------------------------

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Roles, Config, Errors
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-data-var admin principal tx-sender)
(define-map operators principal bool)
(define-data-var paused bool false)

(define-constant ZERO u0)
(define-constant ONE u1)

(define-constant ERR-UNAUTHORIZED (err u401))
(define-constant ERR-NO-POINTS    (err u402))
(define-constant ERR-NOT-CENTER   (err u403))
(define-constant ERR-NO-TYPE      (err u404))
(define-constant ERR-NO-REWARD    (err u405))
(define-constant ERR-STX          (err u406))
(define-constant ERR-BAD-QTY      (err u407))
(define-constant ERR-OVERFLOW     (err u408))
(define-constant ERR-TYPE-OFF     (err u409))
(define-constant ERR-PAUSED       (err u410))
(define-constant ERR-FROZEN       (err u411))
(define-constant ERR-DUP          (err u412))
(define-constant ERR-CAMPAIGN-OFF (err u413))
(define-constant ERR-INSUFFICIENT (err u414))

(define-private (only-admin)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-UNAUTHORIZED)
    (ok true)))

(define-private (only-operator-or-admin)
  (begin
    (asserts! (or (is-eq tx-sender (var-get admin))
                  (default-to false (map-get? operators tx-sender)))
              ERR-UNAUTHORIZED)
    (ok true)))

(define-private (when-active)
  (begin
    (asserts! (not (var-get paused)) ERR-PAUSED)
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core Storage
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Product types
(define-map product-types
  (buff 32)
  {
    name: (string-ascii 30),
    reward: uint,            ;; base reward-per-unit
    active: bool
  }
)

;; Centers (approved verifiers)
(define-map centers principal bool)
(define-map center-performance principal uint) ;; cumulative rewarded units

;; Users
(define-map user-points principal uint)
(define-map rewards-claimed principal uint)
(define-map user-frozen principal bool)

;; User History
(define-map user-history
  {user: principal, index: uint}
  {
    type-id: (buff 32),
    quantity: uint,
    reward: uint,
    timestamp: uint,
    referrer: (optional principal),
    proof: (buff 32)
  }
)
(define-map user-submissions-count principal uint)

;; Anti-fraud: commitment replay protection
(define-map seen-proof (buff 32) bool)

;; Global params
(define-data-var reward-threshold uint u100)
(define-data-var min-block-interval uint u1) ;; rate limit per user submission
(define-map last-submit-height principal uint)

;; Bonus campaigns per type
(define-map campaigns
  (buff 32)
  {
    multiplier: uint,     ;; e.g. 2x = u2
    start: uint,          ;; start block
    end: uint,            ;; end block (inclusive)
    active: bool
  }
)

;; Referral config
(define-data-var referral-bps uint u500) ;; 5% of the user earned point credited to referrer

;; NFT-like Badges (simple)
(define-data-var next-badge-id uint u1)
(define-map badge-owner uint principal)
(define-map badge-thresholds uint uint) ;; badge-id -> points threshold

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Admin & Operators
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (set-admin (new principal))
  (begin
    (try! (only-admin))
    (var-set admin new)
    (ok new)))

(define-public (set-operator (who principal) (is-op bool))
  (begin
    (try! (only-admin))
    (map-set operators who is-op)
    (ok true)))

(define-public (set-paused (p bool))
  (begin
    (try! (only-operator-or-admin))
    (var-set paused p)
    (ok p)))

(define-public (set-reward-threshold (new uint))
  (begin
    (try! (only-operator-or-admin))
    (var-set reward-threshold new)
    (ok new)))

(define-public (set-min-interval (blocks uint))
  (begin
    (try! (only-operator-or-admin))
    (var-set min-block-interval blocks)
    (ok blocks)))

(define-public (set-referral-bps (bps uint))
  (begin
    (try! (only-operator-or-admin))
    (asserts! (<= bps u2000) ERR-UNAUTHORIZED) ;; cap 20%
    (var-set referral-bps bps)
    (ok bps)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Centers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (register-center (center principal))
  (begin 
    (try! (only-admin))
    (map-set centers center true)
    (ok true)))

(define-public (disable-center (center principal))
  (begin
    (try! (only-admin))
    (map-delete centers center)
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Product Types & Campaigns
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (add-product-type (type-id (buff 32)) (name (string-ascii 30)) (reward uint))
  (begin
    (try! (only-operator-or-admin))
    (map-set product-types type-id {name: name, reward: reward, active: true})
    (ok true)))

(define-public (disable-product-type (type-id (buff 32)))
  (let ((p (map-get? product-types type-id)))
    (match p
      data (begin 
             (try! (only-operator-or-admin))
             (map-set product-types type-id (merge data {active: false}))
             (ok true))
      ERR-NO-TYPE)))

(define-public (set-campaign (type-id (buff 32)) (multiplier uint) (start uint) (end uint) (active bool))
  (begin
    (try! (only-operator-or-admin))
    (asserts! (> multiplier ZERO) ERR-OVERFLOW)
    (asserts! (<= start end) ERR-OVERFLOW)
    (map-set campaigns type-id {multiplier: multiplier, start: start, end: end, active: active})
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Reward Pool (Custodied by contract)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Anyone (sponsor, NGO, gov) can fund the reward pool.
(define-public (fund-reward-pool (amount uint))
  (begin
    (try! (when-active))
    (asserts! (> amount ZERO) ERR-NO-REWARD)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (ok amount)))

(define-read-only (get-reward-pool-balance)
  (stx-get-balance (as-contract tx-sender)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Anti-Fraud & User Controls
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (freeze-user (user principal) (state bool))
  (begin 
    (try! (only-operator-or-admin))
    (map-set user-frozen user state)
    (ok state)))

(define-public (slash-user (user principal) (amount uint))
  (begin
    (try! (only-operator-or-admin))
    (let ((pts (default-to ZERO (map-get? user-points user))))
      (map-set user-points user (if (> amount pts) ZERO (- pts amount)))
      (ok true))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Badges (simple NFTs)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (create-badge (threshold uint))
  (begin
    (try! (only-operator-or-admin))
    (let ((id (var-get next-badge-id)))
      (map-set badge-thresholds id threshold)
      (var-set next-badge-id (+ id ONE))
      (ok id))))

(define-read-only (get-badge-owner (id uint)) (map-get? badge-owner id))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core: Submit Recycle
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Centers submit on behalf of the user.
;; - proof: off-chain evidence hash (buff 32)
;; - referrer: optional principal to incentivize growth
(define-public (submit-recycle 
    (user principal) 
    (type-id (buff 32)) 
    (quantity uint) 
    (proof (buff 32)) 
    (referrer (optional principal)))
  (begin 
    (try! (when-active))
    (asserts! (default-to false (map-get? centers tx-sender)) ERR-NOT-CENTER)
    (asserts! (not (default-to false (map-get? user-frozen user))) ERR-FROZEN)
    (asserts! (> quantity ZERO) ERR-BAD-QTY)
    (asserts! (is-none (map-get? seen-proof proof)) ERR-DUP)
    
    (let ((last (default-to ZERO (map-get? last-submit-height user)))
          (minInt (var-get min-block-interval)))
      (asserts! (>= stacks-block-height (+ last minInt)) ERR-PAUSED))
    
    (match (map-get? product-types type-id)
      tinfo (begin
              (asserts! (get active tinfo) ERR-TYPE-OFF)
              (let ((base (* quantity (get reward tinfo))))
                (asserts! (<= base (- (pow u2 u128) u1)) ERR-OVERFLOW)
                (let ((mult (match (map-get? campaigns type-id)
                            camp (if (and (get active camp)
                                        (>= stacks-block-height (get start camp))
                                        (<= stacks-block-height (get end camp)))
                                   (get multiplier camp)
                                   u1)
                            u1)))
                  (let ((total-reward (* base mult)))
                    (asserts! (<= total-reward (- (pow u2 u128) u1)) ERR-OVERFLOW)
                    (let ((result (try! (update-recycle-state user type-id quantity total-reward proof referrer))))
                      (maybe-award-badges user result)
                      (ok result))))))
      ERR-NO-TYPE)
    ));;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Claiming Rewards (custodied pool) - partial or full
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (claim-reward (amount (optional uint)))
  (let (
    (points (default-to ZERO (map-get? user-points tx-sender)))
    (claimed (default-to ZERO (map-get? rewards-claimed tx-sender)))
    (unclaimed (- points claimed))
    (threshold (var-get reward-threshold))
    (pool (stx-get-balance (as-contract tx-sender)))
  )
    (try! (when-active))
    (asserts! (> unclaimed ZERO) ERR-NO-POINTS)
    (asserts! (>= unclaimed threshold) ERR-NO-POINTS)

    (let (
      ;; by default, pay 10% of unclaimed (configurable design)
      (base (/ unclaimed u10))
      (req (match amount a a base))
    )
      (asserts! (> req ZERO) ERR-NO-REWARD)
      (asserts! (<= req unclaimed) ERR-INSUFFICIENT)
      (asserts! (>= pool req) ERR-STX)

      ;; transfer from contract to user
      (try! (as-contract (stx-transfer? req (as-contract tx-sender) tx-sender)))

      ;; account it as fully claimed proportional to payout (linear model)
      (map-set rewards-claimed tx-sender (+ claimed req))
      (ok req)
    )
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Views
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-read-only (get-user-points (user principal))
  (default-to ZERO (map-get? user-points user)))

(define-read-only (get-product-type (type-id (buff 32)))
  (map-get? product-types type-id))

(define-read-only (is-center? (center principal))
  (default-to false (map-get? centers center)))

(define-read-only (get-claimed (user principal))
  (default-to ZERO (map-get? rewards-claimed user)))

(define-read-only (get-user-submissions (user principal))
  (default-to ZERO (map-get? user-submissions-count user)))

(define-read-only (get-user-history (user principal) (index uint))
  (map-get? user-history {user: user, index: index}))

(define-read-only (get-reward-threshold) (var-get reward-threshold))

(define-read-only (get-unclaimed-points (user principal))
  (let ((p (default-to ZERO (map-get? user-points user)))
        (c (default-to ZERO (map-get? rewards-claimed user))))
    (- p c)))

(define-read-only (get-center-performance (center principal))
  (default-to ZERO (map-get? center-performance center)))

(define-read-only (get-campaign (type-id (buff 32)))
  (map-get? campaigns type-id))

(define-read-only (get-referral-bps) (var-get referral-bps))

(define-read-only (is-frozen (user principal))
  (default-to false (map-get? user-frozen user)))

(define-read-only (get-last-submit-height (user principal))
  (default-to ZERO (map-get? last-submit-height user)))

(define-read-only (get-badge-threshold (id uint))
  (map-get? badge-thresholds id))

;; Helper function to update state for recycling submission
;; Handle recycling state updates
(define-private (update-recycle-state 
  (user principal) 
  (type-id (buff 32)) 
  (quantity uint) 
  (reward uint)
  (proof (buff 32))
  (referrer (optional principal))
)
  (let ((old-points (default-to ZERO (map-get? user-points user)))
        (count (default-to ZERO (map-get? user-submissions-count user)))
        (new-points (+ old-points reward)))
    
    ;; Verify final balances
    (asserts! (>= new-points old-points) ERR-OVERFLOW)
    (asserts! (<= new-points (- (pow u2 u128) u1)) ERR-OVERFLOW)
    
    ;; Update core state atomically
    (map-set user-points user new-points)
    (map-set user-submissions-count user (+ count ONE))
    (map-set seen-proof proof true)
    (map-set last-submit-height user stacks-block-height)
    
    ;; Record history
    (map-set user-history {user: user, index: count}
      { type-id: type-id, quantity: quantity, reward: reward,
        timestamp: stacks-block-height, referrer: referrer, proof: proof })
    
    ;; Update center performance
    (let ((center-points (+ (default-to ZERO (map-get? center-performance tx-sender)) quantity)))
      (map-set center-performance tx-sender center-points))
    
    ;; Handle referral if any
    (match referrer
      r (let ((bps (var-get referral-bps))
              (bonus (/ (* reward bps) u10000))
              (ref-points (default-to ZERO (map-get? user-points r)))
              (new-ref-points (+ ref-points bonus)))
          (map-set user-points r new-ref-points))
      false)
    
    ;; Return new point balance
    (ok new-points)))

;; Award badges for points milestone - simplified version that can't fail
(define-private (maybe-award-badges (user principal) (points uint))
  (begin
    ;; Attempt to award each badge level if eligible
    (if (and (is-some (map-get? badge-thresholds u1))
             (>= points (unwrap-panic (map-get? badge-thresholds u1)))
             (is-none (map-get? badge-owner u1)))
        (map-set badge-owner u1 user)
        true)
    
    (if (and (is-some (map-get? badge-thresholds u2))
             (>= points (unwrap-panic (map-get? badge-thresholds u2)))
             (is-none (map-get? badge-owner u2)))
        (map-set badge-owner u2 user)
        true)
    
    (if (and (is-some (map-get? badge-thresholds u3))
             (>= points (unwrap-panic (map-get? badge-thresholds u3)))
             (is-none (map-get? badge-owner u3)))
        (map-set badge-owner u3 user)
        true)
    
    (if (and (is-some (map-get? badge-thresholds u4))
             (>= points (unwrap-panic (map-get? badge-thresholds u4)))
             (is-none (map-get? badge-owner u4)))
        (map-set badge-owner u4 user)
        true)
    
    (if (and (is-some (map-get? badge-thresholds u5))
             (>= points (unwrap-panic (map-get? badge-thresholds u5)))
             (is-none (map-get? badge-owner u5)))
        (map-set badge-owner u5 user)
        true)
    
    true))
