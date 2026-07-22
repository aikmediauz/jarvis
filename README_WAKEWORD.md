# "Hey Jarvis" Wake-Word Setup & Documentation

This document explains how to enable and configure the continuous **"Hey Jarvis"** on-device wake-word detection feature in JARVIS.

## Requirements & Permissions

1. **Microphone Permission:**
   - Go to **Settings > Apps > JARVIS > Permissions > Microphone** and grant **"Allow all the time"** (or allow while app is in use).

2. **Battery Unrestricted Optimization:**
   - To keep wake-word detection running smoothly when JARVIS is in the background or screen is off:
   - Go to **Settings > Apps > JARVIS > Battery** and set it to **"Unrestricted"**.

3. **Picovoice AccessKey Configuration:**
   - Get a free AccessKey from [console.picovoice.ai](https://console.picovoice.ai).
   - Open **JARVIS** app on your phone.
   - Tap on the **Settings (Gear Icon)** dialog.
   - Paste your key into the **Picovoice AccessKey** field.
   - Toggle **Doimiy 'Hey Jarvis' chaqiruvi (Porcupine)** to **ON**.
   - Tap **Saqlash (Save)**.

## How it Works

- When enabled, Picovoice Porcupine listens for the wake word **"Jarvis"** on-device using minimal CPU and battery.
- Saying **"Jarvis"** or **"Hey Jarvis"** automatically brings the app to the foreground and begins active voice command listening.
