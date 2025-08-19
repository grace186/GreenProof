

````markdown
# GreenProof Smart Contract

A Stacks blockchain smart contract for verifying and rewarding recycling activities. GreenProof enables approved centers to verify recycling activities and rewards users with points that can be converted to STX tokens.

## Features

- 🔒 Role-based access control (admin, operators, centers)
- 🏆 Configurable rewards for different recyclable materials
- 🛡️ Built-in anti-fraud measures
- 👥 Referral system with configurable bonus rates
- 🎖️ Achievement badges for milestones
- 💰 Points-to-STX conversion system
- 📈 Campaign multipliers for special events
- 📊 Comprehensive activity tracking

## Contract Details

### Core Components

1. **Roles**
   - Admin: Contract owner with full privileges
   - Operators: Trusted parties who can manage operations
   - Centers: Approved recycling verification centers

2. **Product Types**
   ```clarity
   {
     name: (string-ascii 30),
     reward: uint,
     active: bool
   }
   ```

3. **Campaigns**
   ```clarity
   {
     multiplier: uint,
     start: uint,
     end: uint,
     active: bool
   }
   ```

### Key Functions

#### For Centers
```clarity
(submit-recycle (user principal) (type-id (buff 32)) (quantity uint) (proof (buff 32)) (referrer (optional principal)))
```

#### For Users
```clarity
(claim-reward (amount (optional uint)))
```

#### For Admins
```clarity
(set-operator (who principal) (is-op bool))
(register-center (center principal))
(add-product-type (type-id (buff 32)) (name (string-ascii 30)) (reward uint))
```

## Security Features

- ⚡ Rate limiting for submissions
- 🛑 Emergency pause mechanism
- 🔍 Proof verification system
- 💫 Overflow protection
- ❄️ User freezing capability
- ✂️ Point slashing for violations

## Error Codes

| Code | Description |
|------|-------------|
| 401 | Unauthorized |
| 402 | No Points |
| 403 | Not a Center |
| 404 | Invalid Type |
| 405 | No Reward |
| 406 | STX Error |
| 407 | Bad Quantity |
| 408 | Overflow |
| 409 | Type Inactive |
| 410 | Contract Paused |
| 411 | User Frozen |
| 412 | Duplicate Proof |
| 413 | Campaign Inactive |
| 414 | Insufficient Funds |

## Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/greenproof.git
```

2. Install dependencies:
```bash
npm install
```

3. Deploy using Clarinet:
```bash
clarinet deploy
```

## Testing

Run the test suite:
```bash
clarinet test
```



This README provides a comprehensive overview of your smart contract's features, security measures, and usage instructions. You can save this as `README.md` in your project's root directory.
