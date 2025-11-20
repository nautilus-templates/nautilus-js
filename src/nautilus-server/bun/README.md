# Nautilus Bun Server

This directory contains the Bun/Elysia server that runs inside the Nitro Enclave.

## Directory Structure

```
bun/
├── common/              # DO NOT EDIT - Nautilus infrastructure
│   ├── index.ts        # Main exports
│   ├── nautilus.ts     # Rust FFI bindings
│   └── utils.ts        # Utility functions
├── elysia_server.ts    # Example server (EDIT THIS!)
├── package.json        # Dependencies and scripts
└── README.md           # This file
```

## 🚀 Quick Start

The `elysia_server.ts` is an **example** Twitter verification server. You can:
- Modify it for your use case
- Create a completely new server
- Add multiple files and organize as needed

## 📦 Using the Nautilus Common Library

Import Nautilus functions from `./common`:

```typescript
import {
  generateKeypair,
  getPublicKeyHex,
  getAttestation,
  signIntentMessage,
  nowMs,
  hexToBytes,
  bytesToHex,
  checkEndpointsStatus,
  type NautilusKeypair
} from './common'

// Generate keypair on startup
const keypair = generateKeypair()

// Get public key
const publicKey = getPublicKeyHex(keypair)

// Sign data
const payload = Buffer.from(JSON.stringify({ data: 'hello' }))
const signature = signIntentMessage(keypair, payload, BigInt(Date.now()))
```

**⚠️ DO NOT EDIT** files in the `common/` directory - they are part of the Nautilus template infrastructure.

## 🔧 Customizing Your Server

### Changing the Entry Point

Modify the `start` script in `package.json`:

```json
"scripts": {
  "start": "bun run my_server.ts"  // Use your own file
}
```

### Adding More Files

Create any structure you need:

```
bun/
├── common/              # DO NOT EDIT
├── my_server.ts         # Your entry point
├── lib/
│   ├── auth.ts
│   └── database.ts
└── routes/
    ├── api.ts
    └── webhooks.ts
```

### Adding Dependencies

Just modify `package.json` and run `bun install` locally:

```json
"dependencies": {
  "elysia": "^1.0.0",
  "your-package": "^1.0.0"
}
```

### Using Multiple Workers

```json
"scripts": {
  "start": "bun run --workers=4 elysia_server.ts"
}
```

## 🌍 Environment Variables

Available in your server:
- `BUN_PORT` - Port to listen on (default: 3000)
- `NAUTILUS_LIB_PATH` - Path to Rust FFI library
- `API_KEY` - Your API keys (passed via VSOCK)
- Any other secrets from parent instance

## 📝 Example: Custom Server

```typescript
import Elysia from 'elysia'
import { generateKeypair, signIntentMessage } from './common'

const keypair = generateKeypair()

const app = new Elysia()
  .get('/', () => 'Hello from Nautilus!')
  .post('/sign', ({ body }) => {
    const payload = Buffer.from(JSON.stringify(body))
    return signIntentMessage(keypair, payload, BigInt(Date.now()))
  })
  .listen(3000)

export default app
```
