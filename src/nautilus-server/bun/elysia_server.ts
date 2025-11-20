/**
 * Twitter Example Server
 * 
 * This is an example Elysia server that demonstrates how to use Nautilus
 * to verify Twitter profiles and sign data using the enclave's keypair.
 * 
 * You can modify this file or create your own server implementation!
 */

import Elysia, { t } from 'elysia'
import { openapi } from '@elysiajs/openapi'
import { opentelemetry } from '@elysiajs/opentelemetry'


// Import Nautilus common library (DO NOT EDIT the common/ directory)
import {
  generateKeypair,
  getPublicKeyHex,
  getAttestation,
  signIntentMessage,
  nowMs,
  hexToBytes,
  checkEndpointsStatus,
  type NautilusKeypair
} from './common'

// Generate the enclave's keypair on startup
const keypair: NautilusKeypair = generateKeypair()

const apiKey = process.env.API_KEY || ''

async function fetchTweetContent(user_url: string): Promise<[string, Buffer]> {
  console.log(`[fetchTweetContent] Processing URL: ${user_url}`)
  try {
    if (user_url.includes('/status/')) {
      const m = user_url.match(/x\.com\/\w+\/status\/(\d+)/)
      if (!m) throw new Error('Invalid tweet URL')
      const tweet_id = m[1]
      const url = `https://api.twitter.com/2/tweets/${tweet_id}?expansions=author_id&user.fields=username`
      console.log(`[fetchTweetContent] Fetching tweet API: ${url}`)

      const resp = await fetch(url, {
        headers: { Authorization: `Bearer ${apiKey}` },
        verbose: true
      })

      if (!resp.ok) {
        const errText = await resp.text()
        console.error(`[fetchTweetContent] Twitter API Error (${resp.status}): ${errText}`)
        throw new Error(`Twitter API returned ${resp.status}: ${errText}`)
      }

      const data = await resp.json()
      const tweet_text = data?.data?.text
      if (!tweet_text) {
        console.error('[fetchTweetContent] No tweet text found in response:', JSON.stringify(data))
        throw new Error('Failed to extract tweet text')
      }

      const twitter_name = data?.includes?.users?.[0]?.username
      if (!twitter_name) {
        console.error('[fetchTweetContent] No username found in response:', JSON.stringify(data))
        throw new Error('Failed to extract username')
      }

      const pos = tweet_text.indexOf('#SUI')
      if (pos < 0) throw new Error('No #SUI tag found in tweet')
      const pre = tweet_text.slice(0, pos)
      const addr = pre.match(/0x[0-9a-fA-F]{64}/)?.[0]
      if (!addr) throw new Error('No valid Sui address found')

      return [twitter_name, hexToBytes(addr)]
    } else {
      const m = user_url.match(/x\.com\/(\w+)(?:\/)?$/)
      if (!m) throw new Error('Invalid profile URL')
      const username = m[1]
      const url = `https://api.twitter.com/2/users/by/username/${username}?user.fields=description`
      console.log(`[fetchTweetContent] Fetching user API: ${url}`)

      const resp = await fetch(url, {
        headers: { Authorization: `Bearer ${apiKey}` },
        verbose: true
      })

      if (!resp.ok) {
        const errText = await resp.text()
        console.error(`[fetchTweetContent] Twitter API Error (${resp.status}): ${errText}`)
        throw new Error(`Twitter API returned ${resp.status}: ${errText}`)
      }

      const data = await resp.json()
      const description = data?.data?.description
      if (!description) {
        console.error('[fetchTweetContent] No description found in response:', JSON.stringify(data))
        throw new Error('Failed to extract user description')
      }

      const pos = description.indexOf('#SUI')
      if (pos < 0) throw new Error('No #SUI tag found in profile description')
      const pre = description.slice(0, pos)
      const addr = pre.match(/0x[0-9a-fA-F]{64}/)?.[0]
      if (!addr) throw new Error('No valid Sui address found before #SUI')

      return [username, hexToBytes(addr)]
    }
  } catch (error) {
    console.error('[fetchTweetContent] Exception:', error)
    throw error
  }
}

const port = Number(process.env.PORT ?? 3000)

const app = new Elysia({ tags: ['App'] })
  .use(openapi({
    path: '/openapi',
    documentation: {
      info: { title: 'Nautilus Server', version: '1.0.0', description: 'Bun + Elysia API powered by Rust FFI' },
      tags: [
        { name: 'App', description: 'General endpoints' },
        { name: 'Twitter', description: 'Twitter verification endpoints' }
      ]
    }
  }))
  .use(opentelemetry())
  .get('/', () => 'Pong!', {
    response: t.String(),
    detail: { summary: 'Ping', tags: ['App'] }
  })
  .get('/get_attestation', () => {
    const attestation = getAttestation(keypair)
    return { attestation }
  }, {
    response: t.Object({ attestation: t.String() }),
    detail: { summary: 'Get Nitro attestation', tags: ['App'] }
  })
  .get('/health_check', async () => {
    const pk = getPublicKeyHex(keypair)
    const status = await checkEndpointsStatus()
    return { pk, endpoints_status: status }
  }, {
    response: t.Object({
      pk: t.String(),
      endpoints_status: t.Record(t.String(), t.Boolean())
    }),
    detail: { summary: 'Health check', tags: ['App'] }
  })
  .get('/test/public_key', () => {
    const pk = getPublicKeyHex(keypair)
    return {
      public_key: pk,
      type: typeof pk,
      length: pk.length
    }
  }, {
    response: t.Object({
      public_key: t.String(),
      type: t.String(),
      length: t.Number()
    }),
    detail: { summary: 'Test public key conversion', tags: ['App'] }
  })
  .get('/test/attestation', () => {
    const attestation = getAttestation(keypair)
    return {
      attestation,
      type: typeof attestation,
      length: attestation.length
    }
  }, {
    response: t.Object({
      attestation: t.String(),
      type: t.String(),
      length: t.Number()
    }),
    detail: { summary: 'Test attestation conversion', tags: ['App'] }
  })
  .get('/test/utils', () => {
    const now = nowMs()
    const testHex = '0x1234567890abcdef'
    const bytes = hexToBytes(testHex)
    const hexBack = bytes.toString('hex')
    return {
      timestamp: now,
      timestamp_type: typeof now,
      test_hex: testHex,
      bytes_length: bytes.length,
      hex_back: hexBack
    }
  }, {
    response: t.Object({
      timestamp: t.Number(),
      timestamp_type: t.String(),
      test_hex: t.String(),
      bytes_length: t.Number(),
      hex_back: t.String()
    }),
    detail: { summary: 'Test utility functions', tags: ['App'] }
  })
  .model({
    SignedResponse: t.Object({
      response: t.Object({
        intent: t.Number(),
        timestamp_ms: t.Number(),
        data: t.String()
      }),
      signature: t.String()
    })
  })
  .post('/process_data', async ({ body }) => {
    const user_url = body?.payload?.user_url
    if (!user_url || typeof user_url !== 'string') {
      throw new Error('Invalid user_url')
    }
    const [twitter_name, sui_address] = await fetchTweetContent(user_url)
    const payloadObj = { twitter_name, sui_address: Buffer.from(sui_address).toString('hex') }
    const payloadBuf = Buffer.from(JSON.stringify(payloadObj), 'utf8')
    const ts = BigInt(nowMs())
    const respStr = signIntentMessage(
      keypair,
      payloadBuf,
      ts,
      0
    )
    // Parse the JSON string returned by signIntentMessage and return as object
    const result = JSON.parse(respStr)

    // ------------------------------------------------------------
    // 1️⃣ Convert `intent` from string enum to numeric value
    // ------------------------------------------------------------
    // The Rust side returns an enum as a string (e.g. "ProcessData").
    // The API schema expects a number (0 for ProcessData, 1 for other intents, …).
    // Define a simple mapping here – extend if you add more intents.
    const intentMap: Record<string, number> = {
      ProcessData: 0,
      // add other intent mappings if needed
    }
    if (typeof result.response.intent === 'string') {
      const mapped = intentMap[result.response.intent]
      result.response.intent = typeof mapped === 'number' ? mapped : 0 // fallback to 0
    }

    // ------------------------------------------------------------
    // 2️⃣ Convert `data` from byte array to Base64 string if necessary
    // ------------------------------------------------------------
    // Rust serde_bytes::ByteBuf serializes to a number array in JSON by default.
    if (Array.isArray(result.response.data)) {
      result.response.data = Buffer.from(result.response.data).toString('base64')
    }

    return result
  }, {
    body: t.Object({
      payload: t.Object({
        user_url: t.String({ description: 'x.com user profile or tweet URL' })
      })
    }, { description: 'Twitter URL input' }),
    response: t.Object({
      response: t.Object({
        intent: t.Number(),
        timestamp_ms: t.Number(),
        data: t.String({ description: 'Base64 payload bytes' })
      }),
      signature: t.String({ description: 'Hex-encoded Ed25519 signature' })
    }),
    detail: { summary: 'Process Twitter URL and sign payload', tags: ['Twitter'] }
  })
  .listen({
    port,
    hostname: '0.0.0.0',
    reusePort: true
  })

console.log(`🚀 Nautilus server is running on 0.0.0.0:${port}`)