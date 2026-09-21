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
| **Plan** | Writes a step-by-step plan and stops. Run it later with one tap. |
| **Plan & Execute** | Shows the plan for approval (edit or delete steps), then runs it with verification and recovery. |
| **Auto** | Decides by itself: answers, performs a single action, runs a one-app task, or plans and executes a multi-app job. Asks before sensitive steps (send, call, pay, delete, post). |

### Autonomous execution

`Planner` -> `PlanRunner` -> `TaskExecutor`. Each on-screen step is handed to the existing screen agent, then **verified** against the screen, **retried** with the failure as a hint, and, if it still fails, the rest of the plan is **re-written** (retries and re-plans are configurable). Every run is stored in **Task History** with its mode and plan.

### Memory, preferences, skills

* **Memory** - `memory.md` in the app's private storage. The agent learns durable facts from conversation ("remember that...", or automatically), and you can view, edit and delete them.
* **Preferences** - name, custom instructions, default mode, safety switches.
* **Skills** - reusable recipes you write, or that the agent distils from a task it completed ("Save as skill" on a finished plan). Matching skills are injected into planning; any skill can be run on demand.
* **Learned workflows** - the existing replay memory, now visible and manageable.

### Scheduled tasks

Create tasks in the Schedules screen or just say it in Auto mode ("every weekday at 8 check the weather"). An Android alarm posts a notification at the right time (also after reboot). The task runs immediately if the app is open, otherwise tap the notification. Android does not let an app drive other apps' screens from the background on its own.

### Accounts vault

Logins are stored with the Android Keystore (`flutter_secure_storage`); if the Keystore is unavailable the app falls back to a private file. The model only ever sees an account *label*: passwords are typed into fields locally through a `type_credential` action. The API key uses the same store.

### Talk to the agent

The call button opens a hands-free voice loop: you speak, the agent answers aloud and, in Auto mode, does the task, then listens again. Sensitive steps are confirmed by voice.

### Custom provider

Any OpenAI-compatible endpoint works: set **Base URL**, **API key** and **model** in Settings (OpenRouter, NVIDIA, DeepSeek, local servers, ...).

## Building the release APK

```bash
flutter pub get
flutter test
flutter build apk --release            # build/app/outputs/flutter-apk/app-release.apk
```

Or run the **Android release artifacts** GitHub Action (Actions tab -> Run workflow); it runs the tests and publishes universal and per-ABI APKs. Release builds are signed with the debug key until you add your own signing config in `android/app/build.gradle.kts`.

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
3. The application will maintain a background polling connection to the Telegram API to receive commands.

## License

This project is open-source and available for modification.
