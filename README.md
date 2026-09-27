# PrivateAgent

PrivateAgent is an open-source Android automation agent built with Flutter. It utilizes the DeepSeek API and native Android Accessibility Services to interpret screen layouts and execute multi-step tasks across any installed application via natural language commands.

## Architecture

The system operates on a continuous feedback loop:
1. The user issues a command (via voice, text, or Telegram remote access).
2. The agent captures the current screen hierarchy, calculating the exact spatial coordinates of all interactive elements.
3. The layout data is transmitted to the AI provider alongside the current task context and the result of the previous action.
4. The AI determines the next optimal action (e.g., clicking specific coordinates, inputting text, scrolling).
5. The native Android layer executes the action.
6. The loop repeats until the task is marked as complete.

## Capabilities

- **Screen Reading:** Parses the Android UI tree to map clickable, scrollable, and editable elements.
- **Coordinate-Based Interaction:** Simulates physical screen taps based on coordinate geometry, mitigating issues with missing text labels or inaccessible icons.
- **Remote Access:** Integrates with the Telegram Bot API via background polling, allowing users to issue commands and monitor task execution progress remotely.
- **Voice Control:** Native speech-to-text integration for hands-free operation.

## What's new in 1.1

The original accessibility-based phone-control engine (`AgentAccessibilityService`, `ScreenAutomationService`, `TaskExecutor`) is unchanged in behaviour. Everything below is built around it.

### Five modes

| Mode | What it does |
| --- | --- |
| **Chat** | Fast conversation, no phone control. |
| **Think** | Reasons step by step first; the reasoning appears in a collapsible block. |
| **Plan** | Writes a step-by-step plan and stops. Edit it if you like and run it with one tap. |
| **Plan & Execute** | Plans, then runs it right away with recovery. No approval step. |
| **Auto** | Decides by itself: answers, performs a single action, runs a one-app task, or plans and executes a multi-app job. Asks before sensitive steps (send, call, pay, delete, post). |

### Autonomous execution

`Planner` -> `PlanRunner` -> `TaskExecutor`. Each on-screen step is handed to the existing screen agent. When a step fails, the runner first checks whether the screen is already *past* that step (and marks it done), then retries with the failure as a hint, and finally re-writes the rest of the plan (retries and re-plans are configurable). Optional per-step verification is off by default because it costs one model call per step. Every run is stored in **Task History** with its mode and plan.

### Learns exact workflows from one run

Every successful on-screen task is recorded with the app it ran in, a signature of each screen, and the exact element that was tapped (label, class, centre coordinates). The next time, the task is **replayed without model calls**: it continues the moment the screen looks as recorded, taps the same element (found live, falling back to the recorded coordinates) and confirms it ended on the recorded screen. If anything differs it falls back to the model. Whole requests that worked are also remembered as routines, so repeating them skips planning as well. "open <app>" never needs a model.

Workflows that type one piece of text are learned as **templates**: "open YouTube and search for cats videos" is stored with "cats videos" as a slot. Asking for "search dogs on YouTube" or "on youtube search for slippers" reuses the exact same taps with the new words typed in, no model call for either the routing or the on-screen steps.

### Memory, preferences, skills

* **Memory** - `memory.md` in the app's private storage. The agent learns durable facts from conversation ("remember that...", or automatically), and you can view, edit and delete them.
* **Preferences** - name, custom instructions, default mode, safety switches.
* **Skills** - reusable recipes you write, or that the agent distils from a task it completed ("Save as skill" on a finished plan). Matching skills are injected into planning; any skill can be run on demand.
* **Learned workflows** - the existing replay memory, now visible and manageable.

### Scheduled tasks

Create tasks in the Schedules screen or just say it in Auto mode ("every weekday at 8 check the weather"). Each schedule can use its own model, run in Auto or Plan & Execute, and runs unattended unless you turn on "Ask before sensitive steps". An exact alarm wakes the screen. Because Android blocks apps from opening other apps while they're in the background, a scheduled task that needs to use tools (open an app, tap, type) needs PrivateAgent in front: grant "Display over other apps" (the Schedules screen prompts for this) so it can bring itself forward by itself; without it, tap the notification first. A PIN/pattern lock still blocks driving other apps until you unlock the phone. The result is reported in a notification.

### Accounts vault

Logins are stored with the Android Keystore (`flutter_secure_storage`); if the Keystore is unavailable the app falls back to a private file. The model only ever sees an account *label*: passwords are typed into fields locally through a `type_credential` action. The API key uses the same store.

### Faster and more efficient

- Screens are read once per step instead of twice; fixed multi-second waits are replaced by a wait that ends as soon as the screen stops changing. Per-step verification is a model call and stays off by default.
- The planner writes coarse steps ("search for cats on YouTube", not "tap the search icon"). If a step's result is already visible after a failure, the runner marks it done rather than retrying or re-planning.
- "open Instagram" and anything else with no room for interpretation runs with no model call.
- Stop is immediate: it aborts in-flight network requests directly, not just after they time out, and force-clears the UI a few seconds later if anything is still winding down.
- The API key is kept in both encrypted storage and preferences, so it survives a Keystore reset and is never asked for again after Settings.

### Talk to the agent

The call button opens a hands-free voice loop with real voice-activity detection: it starts listening as soon as you speak and stops as soon as you go quiet (about a second of silence), rather than waiting out a fixed window either way. While the agent is thinking or controlling the phone the microphone is off — it never listens to itself, its own screen-automation, or picks up background noise mid-task — and it starts listening again once it has a reply. The agent answers aloud, sentence by sentence while it is still writing. It ends when you say bye, from a long silence, or the Hang up button/notification.

The call keeps running while other apps are open, via a microphone foreground service with a Hang up notification. If you grant "Display over other apps" (asked once, the first time you call; there's also a manual toggle in Agent preferences), a small status pill floats over whatever app is open — listening / thinking / controlling your phone — so you can see what it's doing without switching back.

By default it speaks with the phone's own text-to-speech, nudged toward a more natural installed voice where the device offers one. For a noticeably more natural voice, point **Custom call voice server** (Agent preferences) at a self-hosted [Piper](https://github.com/rhasspy/piper) HTTP server — `python3 http_server.py --model <voice>.onnx` — and calls speak through that instead, falling back to the system voice if the server doesn't respond.

Skills you've created run in calls too (and everywhere else): saying a skill's name or one of its trigger phrases runs it directly, without waiting on the model to decide to use it.

### Custom provider

Any OpenAI-compatible endpoint works: set **Base URL**, **API key** and **model** in Settings (OpenRouter, NVIDIA, DeepSeek, local servers, ...).

## Building the release APK

```bash
flutter pub get
flutter test
flutter build apk --release            # build/app/outputs/flutter-apk/app-release.apk
```

Or run the **Android release artifacts** GitHub Action (Actions tab -> Run workflow); it runs the tests and publishes universal and per-ABI APKs.

**Signing.** Without a key, release builds fall back to the debug key, which is fine to try but cannot receive updates that survive reinstall. To sign properly: create `android/key.properties` (never commit it - it's gitignored) pointing at a keystore:

```
storePassword=...
keyPassword=...
keyAlias=...
storeFile=release.jks   # placed in android/app/
```

`flutter build apk --release` then signs with it automatically. For the GitHub Action, add repo secrets `KEYSTORE_BASE64` (the keystore file, base64-encoded), `KEYSTORE_PASSWORD` and `KEY_ALIAS`; the workflow writes `key.properties` itself and the build picks it up. Skip the secrets and it still builds, debug-signed.

## Installation

Download the latest APK directly from the [Releases Page](https://github.com/orailnoor/private-agent/releases).

Choose `app-universal-release.apk` when it is available. It supports ARM64,
32-bit ARM, and x86_64 devices in one package. If a release only provides split
APKs, most modern Android phones—including Snapdragon devices—must use
`app-arm64-v8a-release.apk`.

PrivateAgent supports Android 8.0 (API 26) and newer. Current release builds are
also checked for Android 15/16's 16 KB native-library alignment requirement.

## Setup Instructions (How to use for FREE)

This app requires an AI brain to operate. You can use it **100% for free** by using OpenRouter's free models.

1. Install the APK on your Android device (API 30+ recommended).
2. Go to [OpenRouter.ai](https://openrouter.ai/) and create a free account.
3. Generate a free API Key.
4. Launch PrivateAgent and go to the **Settings** screen.
5. Tap the **"OpenRouter"** quick-select chip under Base URL.
6. Paste your API Key.
7. Type `openai/gpt-oss-120b:free` (or any other free model) into the Model field.
8. Enable the **"PrivateAgent Screen Control"** service in your Android Accessibility Settings.

### “Restricted setting” when enabling Screen Control

Android may block accessibility access for apps installed from an APK. This is
an operating-system safety restriction:

1. Open **Settings → Apps → PrivateAgent**.
2. Open the three-dot menu in the top-right corner.
3. Tap **Allow restricted settings** and confirm.
4. Return to PrivateAgent and open **Accessibility Settings** again.
5. Enable **PrivateAgent Screen Control**.

PrivateAgent now shows these instructions and provides shortcuts to both App
Info and Accessibility Settings during onboarding.

## Telegram Integration

To enable remote access:
1. Acquire a bot token from BotFather on Telegram.
2. Input the token in the PrivateAgent Settings screen and enable the integration toggle.
3. The app polls Telegram for messages and keeps doing so in the background via a small foreground service, so it stays reachable with the screen off or another app open.

A Telegram message goes through the same Auto-mode agent the app itself uses — multi-step tasks, learned workflows and skills, memory, everything — not just single actions, and runs unattended (no confirmation prompts; nobody's there to answer them). If "Display over other apps" is granted, it wakes the screen and brings PrivateAgent forward so the command can actually reach the screen; otherwise nothing can drive the screen while the app is backgrounded, which is an Android restriction, not something this app can route around.

## License

This project is open-source and available for modification.
