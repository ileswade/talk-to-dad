# Talk to Dad (TTD)

Two apps and a relay so family members can talk with an older parent through his Mac: type a message, his Mac speaks it, listens to his answer and sends back the words and the recording.

## Talk to Dad.app — on Dad's Mac (menu bar, starts at login)
- Speaks messages in a natural voice (Kokoro-82M via FluidAudio 0.17.7 on the Neural Engine; bundled, no downloads). Iles = am_adam, Nicole = af_heart. Loudness boost and speed (🐢/🐇 in the status bar).
- Listens for Dad's answer (Apple on-device speech recognition), keeps the recording, labels who he was talking to.
- Big buttons for Dad: blue "Talk to Iles", pink "Talk to Nicole", Clear (hides the screen; history kept).
- Chat sessions: chime + "Message from …" only at the start of a chat (5 min idle ends a chat).
- Reads new iMessages from the family's numbers (entered in Settings) aloud. Never reads history (date-based). Needs Full Disk Access.
- Optional: send Dad's answers back by iMessage (Off / Text / Text + recording). Needs Automation → Messages.
- Relay connection: family messages spoken; every chat line (with Dad's audio) sent to the family app; presence (idle time, locked, speaking/listening); screenshot (Screen Recording permission) and camera photo (Camera permission) on request.
- Data: `~/Library/Application Support/Talk to Dad/` (Conversation/, Models/); relay key in `~/Library/Application Support/com.ris.talktodad/relayKey` (mode 600, not Keychain: a self-signed app would prompt Dad on every update).

## TTD Family.app — on Iles's / Nicole's Macs
Chat with Dad's Mac from anywhere, play his recordings, see "Active now / Last active … / Screen locked", take a screenshot or camera photo (saved in `~/Library/Application Support/TTD Family/pictures`). Settings: I am (Iles/Nicole), relay address, family key.

## Relay — Cloudflare Worker + Durable Object (`relay/`)
Both sides connect outbound (`/ws?role=dad|family`, `Authorization: Bearer <key>`). Keeps last 300 lines (text only), queues messages while Dad's Mac is offline. Secrets DAD_TOKEN / FAMILY_TOKEN (Hermes). Local test: `npx wrangler dev --local` then `node test-relay.mjs`. Deployment: sys.cloud.

## Build
Run Talk to Dad once on this Mac (fetches models), then `./build-app.sh` → `dist/Talk to Dad.app`, `dist/Talk-to-Dad.dmg`, `dist/TTD Family.app`, `dist/TTD-Family.zip` (ad-hoc signed).
Self-test: `TALKTODAD_SELFTEST=/tmp/t.wav "dist/Talk to Dad.app/Contents/MacOS/TalkToDad"`.

## Install on Dad's Mac (fresh Mac, no Xcode)
Open the DMG, drag to Applications, open; Privacy & Security → Open Anyway; allow Microphone, Speech Recognition; then Full Disk Access (texts), Screen Recording (screenshots), Camera (photos), Automation → Messages (only if replies by text are on). Settings → Family app connection: relay address + Dad's key.
