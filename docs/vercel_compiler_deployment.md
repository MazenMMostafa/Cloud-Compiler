# Deploying the NewBegin Arduino Uno Cloud Compiler to Vercel

This document explains how to deploy this backend (`newbegin_compiler_server`)
to Vercel as a Docker container and point the Flutter app at the public
HTTPS endpoint.

## What is deployed

A Dart HTTP server that receives Arduino source code, compiles it for the
Arduino Uno (`arduino:avr:uno`) with `arduino-cli` + the AVR toolchain
(pre-installed in the image), and returns the generated Intel HEX firmware.

Endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Liveness. Never protected, never compiles. |
| `/compile` | POST | Compile `{"source": "...", "board": "arduino_uno", "format": "hex"}` → `{"success": true, "firmware": "<base64 hex>", ...}` |

## 1. Create a GitHub repository

1. Go to https://github.com and click **New repository**.
2. Name it e.g. `newbegin-compiler`.
3. Choose **Public** or **Private** (either works with Vercel).
4. Do **not** initialize with a README/.gitignore yet — this repo already has one.
5. Click **Create repository**.

## 2. Push the compiler backend

From the backend project root (the folder containing `Dockerfile.vercel`,
`bin/`, `lib/`, `pubspec.yaml`):

```bash
git init
git add .
git commit -m "Initial commit: NewBegin Arduino Uno cloud compiler"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/newbegin-compiler.git
git push -u origin main
```

Do **not** commit secrets. `.env` files and the bundled `tools/arduino-cli*`
binaries are already ignored by `.gitignore`.

## 3. Import the repository into Vercel

1. Go to https://vercel.com/new.
2. Choose **Import Git Repository** and connect GitHub.
3. Select the `newbegin-compiler` repository.
4. Vercel will detect the project. **Choose the Docker image deployment
   (Vercel "Docker" / container runtime)** and point it at the `Dockerfile.vercel` file.
   - Framework Preset: `Docker` / custom container.
   - Build Command / Dockerfile: `Dockerfile.vercel`.
5. Add the environment variables from section 4.
6. Click **Deploy**.
7. Vercel assigns a public URL like `https://newbegin-compiler.vercel.app`.

Note: the Docker/container runtime on Vercel is a preview feature. If your
account does not show it, deploy the same image on any other container host
(DigitalOcean App Platform, Fly.io, Railway, Render) using the identical
`Dockerfile.vercel` — the code does not care where it runs.

## 4. Required Vercel environment variables

Set these in **Project → Settings → Environment Variables**:

| Variable | Required | Example | Notes |
|----------|----------|---------|-------|
| `PORT` | No | (Vercel sets it) | Vercel injects `PORT` automatically. |
| `COMPILER_API_KEY` | No | `a-strong-random-string` | When set, `/compile` requires header `X-API-Key: <value>`. `/health` stays open. Generate with `openssl rand -hex 32`. |
| `ARDUINO_CLI_PATH` | No | (unset) | Defaults to `arduino-cli` on PATH (bundled in the image). |

Do **not** put the API key in source control. Use the Vercel dashboard (or
`vercel env add`).

## 5. Test `/health`

```bash
curl https://PROJECT_NAME.vercel.app/health
```

Expected response:

```json
{
  "success": true,
  "service": "newbegin-arduino-compiler",
  "board": "arduino:avr:uno"
}
```

`/health` never starts a compilation.

## 6. Test `/compile`

Compile a minimal Arduino Uno blink program:

```bash
curl -X POST https://PROJECT_NAME.vercel.app/compile \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_KEY" \
  -d '{
    "source": "void setup() { pinMode(13, OUTPUT); } void loop() { digitalWrite(13, HIGH); delay(500); digitalWrite(13, LOW); delay(500); }",
    "board": "arduino_uno",
    "format": "hex"
  }'
```

A successful response contains `"success": true` and a `firmware` field that is
base64-encoded Intel HEX (decoded text begins with `:`). Omit the `X-API-Key`
header only if `COMPILER_API_KEY` was not configured.

## 7. Build Flutter with the public endpoint

From the Flutter app root (`NewBegin Robotics`):

```bash
flutter build apk --release \
  --dart-define=COMPILER_BASE_URL=https://PROJECT_NAME.vercel.app \
  --dart-define=COMPILER_API_KEY=YOUR_KEY
```

- `COMPILER_BASE_URL` seeds the app's cloud compiler URL. The app calls
  `POST $COMPILER_BASE_URL/compile`.
- `COMPILER_API_KEY` seeds the API key; the client adds header
  `X-API-Key` only when this value is non-empty.
- The URL/key can still be overridden at runtime in the app's Compiler
  settings screen.

## 8. Redeploy after a GitHub push

Vercel auto-deploys on every push to the default branch:

```bash
git add .
git commit -m "Update compiler server"
git push origin main
```

Watch the deployment in the Vercel dashboard (Deployments tab). Redeploy a
previous build or trigger a fresh one with **Redeploy** if needed.

## 9. Rotating the API key

If you suspect the key leaked (it is extractable from the APK, see section 11):

1. Generate a new key:

   ```bash
   openssl rand -hex 32
   ```

2. In Vercel, open **Project → Settings → Environment Variables**, replace the
   `COMPILER_API_KEY` value, and redeploy (a push or **Redeploy**).
3. Rebuild and reinstall the APK with the new `COMPILER_API_KEY` dart-define
   (section 7) — old APKs stop working.
4. Test `POST /compile` with the new key; the old key must now return `401`.

## 10. Known limitations of the Vercel deployment

- **Container runtime is a preview feature.** Limits (memory, CPU, cold
  starts, maximum execution time) may differ from regular serverless
  functions. Compilation can be slow (AVR toolchain startup); cold starts add
  latency.
- **No persistent disk.** Every request writes to `/tmp` and deletes it in a
  `finally` block. There is no firmware cache.
- **Arduino Uno only.** Other boards (Mega, ESP32, ESP8266) are rejected with
  a clear error because the image only bundles the AVR core.
- **Single compile at a time may be slow.** The endpoint supports concurrent
  requests (each uses its own temp dir), but CPU limits mean heavy parallel
  use will queue.
- **The 512 KB request-body cap** means very large sketches are rejected.
- **Vercel may have an idle scale-down.** The first request after idle can be
  slow or time out client-side; retry.

## 11. Security warning: the APK API key is not authentication

If you embed `COMPILER_API_KEY` via `--dart-define`, the key is compiled into
the APK/DEX. Anyone with the APK can extract it with simple tooling. The key
only slows down casual abuse; it is **not** strong authentication.

If you need real protection, put the key behind an authenticated proxy, add
per-user keys on the server, or call the compiler from a server that holds the
key instead of the client.

## Local container verification

```bash
docker build -f Dockerfile.vercel -t newbegin-compiler .
docker run --rm -p 8080:3000 -e PORT=3000 -e COMPILER_API_KEY=test-secret newbegin-compiler
curl http://localhost:8080/health
curl -X POST http://localhost:8080/compile \
  -H "Content-Type: application/json" -H "X-API-Key: test-secret" \
  -d '{"source":"void setup(){pinMode(13,OUTPUT);} void loop(){digitalWrite(13,HIGH);delay(500);digitalWrite(13,LOW);delay(500);}","board":"arduino_uno","format":"hex"}'
```
