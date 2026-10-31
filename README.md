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

(v23: the bundled natural voices were removed — they were slow and sounded worse than the system voice; everything now speaks with the phone's own text-to-speech.) The older description follows: by default it speaks with the phone's own text-to-speech, nudged toward a more natural installed voice where the device offers one. Replies were spoken with **built-in natural offline voices** (Piper English "Lessac" and Hindi "Pratham", run through the official k2-fsa `sherpa_onnx` Flutter package, bundled in `assets/voices`) — nothing to download or run, and the right voice is chosen from the reply's language. If they can't start, the phone's own speech engine speaks instead, and a crash guard switches the natural voice off after two interrupted attempts in a row (Agent preferences → Voice lets you retry, or pick the System voice and its English/Hindi voices).

Skills you've created run in calls too (and everywhere else): saying a skill's name or one of its trigger phrases runs it directly, without waiting on the model to decide to use it.

> **v23:** the bundled natural offline voices (and `sherpa_onnx`, `audioplayers`, `assets/voices`) were removed. They were slower and sounded worse than the system voice; all speech now uses the phone's own text-to-speech, and the older paragraph about natural voices above no longer applies.

### App assistant (button next to "Talk to the agent")

Voice first, like "Talk to the agent" but inside the app you are using. Tap the button (or just ask while talking to the agent: "buy wireless earbuds on Amazon", "what's the price of this"), PrivateAgent steps aside and you open the app you want help in. Talk to it: "price?", "is it good?", "how many subscribers", "scroll to the reviews and open them". Answers are read off the live screen and spoken, and a **big text card** (price, rating, subscribers...) pops up over the app exactly when it talks about the content. A small status pill shows what it is doing. Say "close assistant" when done.

Buying asks **twice**: when the risky task starts and again at checkout, answered by voice (yes / no / haan / nahi) or by tapping the card. Agent preferences -> App assistant -> "Fully autonomous buying" skips both (off by default). Needs "Display over other apps" and the accessibility service.

**Hand-offs from "Talk to the agent":** asking it to call someone and talk starts talk mode, and buying/ordering/price questions in shopping apps start the app assistant. The voice call goes completely quiet while that runs (mic off) and resumes with a short update when it ends. YouTube and other apps are handled by the agent itself.

**Bigger jobs go to a stronger app:** image generation opens Gemini; websites, apps and other large builds open Claude (and fall back to Gemini if Claude's usage limit is hit). Simple things — rewording a message, short answers — stay with the agent.

### Call someone and talk to them (virtual cable)

Say "call Ravi on WhatsApp and ask whether Friday works" (Auto mode). The agent asks for your OK (a call is a sensitive step), then:

1. starts the **virtual cable** (needs Shizuku running and allowed),
2. opens WhatsApp (or Telegram) and taps through to the voice call like a person would (you can also place the call yourself if it gets stuck),
3. the moment the call is up (Android switches to call audio mode), switches on **talk mode** by itself: it follows your brief, speaks as you, and answers what the other person says. It says it is an AI if they sincerely ask.

How the cable works: a helper (`CableMain`, shipped inside the APK) is launched through Shizuku with `app_process`, so it runs as the shell user, which holds `MODIFY_AUDIO_ROUTING`. It registers an Android audio policy whose RECORDER mix catches every microphone recording made by WhatsApp / Telegram / Signal and feeds it from an `AudioTrack` instead. The neural (or system) voice is streamed to the helper over `127.0.0.1`, so it reaches the call as if it were the microphone: no speaker, no echo. The cable must be up *before* the call app opens its microphone, which is why it starts first. If it cannot start, talk mode falls back to the loudspeaker. Hearing the other person still uses the phone's live captions (microphone as a last resort).

**Speed:** replies stream and are spoken sentence by sentence, the prompt is minimal, captions settle in 0.65 s, and there is no echo delay with the cable. Agent preferences -> Talk mode lets you set a separate (fast, non-reasoning) API key / base URL / model just for calls. Live captions are switched on through Shizuku when the phone supports it (Android Live Caption; Xiaomi AI Subtitles may need switching on once by hand).

**Full automation** (Agent preferences -> Talk mode): no confirmation before calling, short stalling fillers if the model is slow, the agent hangs up when the goal is done (or the other side hangs up), and a report of the call appears as a notification and on the Talk screen.

Settings -> Talk on my call does the same by hand. Agent preferences -> Call audio test -> "Play test tone into a call" checks the cable end to end. A normal SIM call cannot be used: its audio never passes through an app microphone.

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


## Backup providers (automatic fallback)

Settings → **Backup providers** lets you add extra OpenAI-compatible providers (base URL, key, model). If the main provider fails, requests move to the next one and keep cycling (two full rounds, at least 4 attempts). With only one provider, it is retried up to 4 times (with growing pauses) before the task ends. After switching to a backup it stays there for 10 minutes, then tries the main provider first again. Pressing Stop is never retried.


## Building the APK

`.github/workflows/build-apk.yml` builds the release APK from a clean checkout (Java 17, stable Flutter, `flutter pub get`, `flutter build apk --release --target-platform android-arm64`) and uploads `app-release.apk` as an artifact. Without signing secrets it signs with the debug key; to sign with your own key, add the repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`.

## People, settings and walkthroughs

- **Aliases:** Agent preferences → *People & walkthroughs*. Give people nicknames ("mom", "boss"), an optional number and the app you use for them. The agent is told about them on every request, and call / SMS / WhatsApp actions resolve them directly. It also learns which app you usually use for a contact.
- **Quick settings:** the `system_setting` action turns Wi-Fi, Bluetooth, airplane mode, mobile data, location, NFC, Do Not Disturb, battery saver and auto-rotate on/off directly when Shizuku is available; otherwise it opens the exact Settings page/panel and lets the screen automation finish the toggle. It can also open display, sound, battery, accessibility, apps and other settings pages.
- **Opening apps:** `open_app` launches directly from wherever you are and checks the app really came to the front. Only if Android blocked the launch does it try Shizuku, and then the launcher icon as a last resort.
- **Walkthroughs:** after a phone task succeeds, a short step-by-step walkthrough (no typed text stored) is saved, listed in *People & walkthroughs*, and given to the agent as a guide for similar tasks.

## Talk on my call (WhatsApp / Telegram)

Settings → *Talk on my call*. You write a short brief; once the call is running the agent speaks as you and answers the other person. Android gives apps no audio link into another app's call, so it works like this: it **hears** the other person through the phone's live captions (Xiaomi AI Subtitles / Google Live Caption, read via the accessibility service — falling back to the microphone's "voice recognition" source), and **speaks** through the speaker while the call is on speaker, without taking audio focus from the call. The *Call audio test* in Agent preferences shows what your device supports. The agent says it is an AI if asked sincerely.

### v23: multiple IR commands
`send_ir` accepts `{"names": ["tv power", "tv volume up x3"]}` and fires them 0.2 s apart.
