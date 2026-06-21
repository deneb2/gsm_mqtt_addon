# GSM MQTT Bridge

This Home Assistant add-on bridges a GSM/cellular modem to MQTT: it publishes missed-call notifications and inbound SMS, and accepts SMS-sending commands.
The add-on is designed to integrate modem functionality (missed call detection, SMS sending and receiving) with Home Assistant.

## Features

- **Modem Event Monitoring**: Detects missed calls from connected GSM modem and publishes to MQTT
- **SMS Sending**: Send SMS messages via MQTT commands from Home Assistant automations
- **SMS Receiving**: Publishes inbound SMS to MQTT with sender, ISO 8601 timestamp, and body; deletes from SIM after publish
- **Status Feedback**: Publishes SMS delivery status back to MQTT
- **Unified Gammu Architecture**: Single tool for all modem operations - no serial port conflicts
- **Deduplication**: Tracks processed calls and SMS to avoid duplicate notifications
- Easy to configure through the Home Assistant GUI

## Installation Instructions

To install the GSM MQTT Bridge add-on in Home Assistant OS (HAOS), follow these steps:

1. **Add the Repository**:
   - Go to the **Settings** section of Home Assistant.
   - Click on **Add-ons**.
   - Select **Add-on Store** from the menu.
   - Click on the three-dot menu in the top right corner and choose **Repositories**.
   - Add the repository URL where your add-on resides (the URL to your `repository.yaml`).

2. **Install the Add-On**:
   - Find **GSM MQTT Bridge** in your add-on store.
   - Click on it and then click on the **Install** button.

3. **Configure the Add-On**:
   After installation, navigate to the **Configuration** tab. Set the following options:
   - `mqtt_host`: The hostname of your MQTT broker (default is `localhost`).
   - `mqtt_port`: The port of your MQTT broker (default is `1883`).
   - `mqtt_user`: Your MQTT username.
   - `mqtt_pass`: Your MQTT password.
   - `mqtt_topic`: The base topic for modem events (default is `home/gsm_mqtt`).
   - `serial_port`: The serial port where your GSM modem is connected (default is `/dev/ttyUSB2`).
   - Click **Save**.

4. **Start the Add-On**:
   - Go to the **Info** tab and click on **Start** to run the add-on.

## MQTT Topics

The add-on uses the following MQTT topics (assuming `mqtt_topic` is set to `home/gsm_mqtt`):

- **Subscribe Topics** (add-on listens to these):
  - `home/gsm_mqtt/send_sms` - Send SMS commands to the modem

- **Publish Topics** (add-on publishes to these):
  - `home/gsm_mqtt` - Modem events (missed calls, plain text payload)
  - `home/gsm_mqtt/sms_status` - SMS delivery status feedback (JSON: `{number, status, timestamp[, error]}`)
  - `home/gsm_mqtt/sms_received` - Inbound SMS (JSON: `{from, timestamp, body}`, timestamp is ISO 8601 with TZ offset)

## Sending SMS from Home Assistant

### Method 1: Direct MQTT Publish (Simplest)

Use the `mqtt.publish` service directly in your automations:

```yaml
alias: "Send SMS Alert"
description: "Send SMS when motion detected"
triggers:
  - trigger: state
    entity_id: binary_sensor.motion_detector
    to: "on"
conditions: []
actions:
  - action: mqtt.publish
    data:
      topic: "home/gsm_mqtt/send_sms"
      payload: >
        {
          "number": "+1234567890",
          "message": "Motion detected at {{ now().strftime('%H:%M:%S') }}!"
        }
mode: single
```

### Method 2: Create a Script for Reusability (Recommended)

Add to your `scripts.yaml`:

```yaml
send_sms:
  alias: "Send SMS via Modem"
  fields:
    phone_number:
      description: "Phone number to send to"
      example: "+1234567890"
    sms_message:
      description: "Message to send"
      example: "Hello from Home Assistant"
  sequence:
    - action: mqtt.publish
      data:
        topic: "home/gsm_mqtt/send_sms"
        payload: >
          {
            "number": "{{ phone_number }}",
            "message": "{{ sms_message }}"
          }
```

Then use it in automations:

```yaml
alias: "Door Open SMS Alert"
description: "Send SMS when front door opens"
triggers:
  - trigger: state
    entity_id: binary_sensor.front_door
    to: "on"
conditions: []
actions:
  - action: script.send_sms
    data:
      phone_number: "+1234567890"
      sms_message: "Front door opened at {{ now().strftime('%H:%M') }}"
mode: single
```

### Method 3: Quick Test from Developer Tools

Go to **Developer Tools → Services**:

**Service:** `mqtt.publish`  
**Service Data:**
```yaml
topic: home/gsm_mqtt/send_sms
payload: '{"number": "+1234567890", "message": "Test from Home Assistant"}'
```

Click **"Call Service"** to send a test SMS!

## Quick Reference

### Send SMS in Automation (Copy-Paste Template)

**IMPORTANT: Use single-line JSON format!**

```yaml
- action: mqtt.publish
  data:
    topic: "home/gsm_mqtt/send_sms"
    payload: '{"number": "+1234567890", "message": "Your message here"}'
```

### Send SMS with Dynamic Content

```yaml
- action: mqtt.publish
  data:
    topic: "home/gsm_mqtt/send_sms"
    payload: '{"number": "+1234567890", "message": "Alert at {{ now().strftime(''%H:%M'') }}: {{ trigger.to_state.state }}"}'
```

**Note:** Use `''` (two single quotes) to escape quotes inside single-quoted strings, OR use `>-` with proper JSON formatting on a single line.

## Automation Examples

### Example 1: Missed Call Notification

Receive Home Assistant notification when someone calls the modem:

```yaml
alias: "Notify on Missed Call"
description: "Get notification when modem receives a call"
triggers:
  - trigger: mqtt
    topic: home/gsm_mqtt
    enabled: true
conditions: []
actions:
  - action: notify.notify
    data:
      message: "{{ trigger.payload }}"
      title: "Modem Alert"
mode: single
```

### Example 2: Temperature Alert via SMS

Send SMS when temperature exceeds threshold:

```yaml
alias: "High Temperature SMS Alert"
description: "Send SMS when temperature is too high"
triggers:
  - trigger: numeric_state
    entity_id: sensor.living_room_temperature
    above: 30
conditions: []
actions:
  - action: mqtt.publish
    data:
      topic: "home/gsm_mqtt/send_sms"
      payload: >
        {
          "number": "+1234567890",
          "message": "Temperature alert! Living room: {{ states('sensor.living_room_temperature') }}°C at {{ now().strftime('%H:%M') }}"
        }
mode: single
```

**Or using the script (if you created it):**

```yaml
alias: "High Temperature SMS Alert"
description: "Send SMS when temperature is too high"
triggers:
  - trigger: numeric_state
    entity_id: sensor.living_room_temperature
    above: 30
conditions: []
actions:
  - action: script.send_sms
    data:
      phone_number: "+1234567890"
      sms_message: "Temperature alert! Living room: {{ states('sensor.living_room_temperature') }}°C"
mode: single
```

### Example 3: Alarm System Integration

Send SMS to multiple recipients when alarm is triggered:

```yaml
alias: "Alarm Triggered - SMS Alert"
description: "Send SMS to emergency contacts when alarm triggers"
triggers:
  - trigger: state
    entity_id: alarm_control_panel.home_alarm
    to: "triggered"
conditions: []
actions:
  - action: mqtt.publish
    data:
      topic: "home/gsm_mqtt/send_sms"
      payload: >
        {
          "number": "+1234567890",
          "message": "ALARM TRIGGERED at {{ now().strftime('%Y-%m-%d %H:%M:%S') }}! Check cameras."
        }
  - action: mqtt.publish
    data:
      topic: "home/gsm_mqtt/send_sms"
      payload: >
        {
          "number": "+0987654321",
          "message": "ALARM TRIGGERED at {{ now().strftime('%Y-%m-%d %H:%M:%S') }}! Check cameras."
        }
mode: single
```

### Example 4: Daily Status Report

Send daily SMS with home status:

```yaml
alias: "Daily SMS Status Report"
description: "Send daily home status via SMS"
triggers:
  - trigger: time
    at: "08:00:00"
conditions: []
actions:
  - action: mqtt.publish
    data:
      topic: "home/gsm_mqtt/send_sms"
      payload: >
        {
          "number": "+1234567890",
          "message": "Good morning! Home status: Temp {{ states('sensor.temperature') }}°C, All systems OK"
        }
mode: single
```

### Example 5: Power Outage Alert

Alert via SMS when power outage is detected:

```yaml
alias: "Power Outage SMS Alert"
description: "Send SMS when main power fails"
triggers:
  - trigger: state
    entity_id: binary_sensor.power_status
    to: "off"
conditions: []
actions:
  - action: mqtt.publish
    data:
      topic: "home/gsm_mqtt/send_sms"
      payload: >
        {
          "number": "+1234567890",
          "message": "⚡ Power outage detected at {{ now().strftime('%H:%M') }}! Running on backup."
        }
mode: single
```

### Example 6: Monitor SMS Delivery Status

Track SMS delivery status:

```yaml
alias: "SMS Delivery Status Monitor"
description: "Log SMS delivery status"
triggers:
  - trigger: mqtt
    topic: home/gsm_mqtt/sms_status
conditions: []
actions:
  - action: notify.persistent_notification
    data:
      message: >
        SMS Status: {{ trigger.payload_json.status }}
        To: {{ trigger.payload_json.number }}
        Time: {{ trigger.payload_json.timestamp }}
      title: "SMS Delivery Update"
mode: queued
```

### Example 7: Notify on Inbound SMS

Get a Home Assistant notification whenever the modem receives a new SMS:

```yaml
alias: "Notify on Inbound SMS"
description: "Notification when the modem receives an SMS"
triggers:
  - trigger: mqtt
    topic: home/gsm_mqtt/sms_received
conditions: []
actions:
  - action: notify.notify
    data:
      title: "SMS from {{ trigger.payload_json.from }}"
      message: "{{ trigger.payload_json.body }}"
mode: queued
```

The `timestamp` field is ISO 8601 with timezone offset (e.g. `2025-10-21T15:02:00+0200`), so it works directly with Home Assistant's `as_datetime` / `as_timestamp` helpers if you want to compare against `now()`.

## Troubleshooting

### SMS Not Sending

1. Check the add-on logs for error messages
2. Verify your modem is connected and shows up as `/dev/ttyUSBx`
3. Ensure the serial port in configuration matches your modem
4. Test modem connectivity: `gammu -c /tmp/gammurc identify` (from inside the container)
5. Check MQTT broker connection
6. Check the queue file: `cat /tmp/sms_queue` (from inside the container)

### Modem Not Detected

1. Check USB connection
2. Verify device appears in `/dev/` directory
3. Install `usb-modeswitch` if needed
4. Check add-on has proper device permissions

### Conflicts with Other Add-ons

This add-on uses Gammu exclusively for all serial port access. If you experience issues:
1. Don't run multiple add-ons that access the same serial port simultaneously
2. Check add-on logs for Gammu errors or serial port access issues
3. Verify the SIM exposes a Missed-Calls phonebook: `gammu -c /tmp/gammurc getmemory MC 1 5` from the addon shell
4. If that returns "Function not supported", missed-call detection cannot work on this modem

### Modem Doesn't Support Call Logs

If you see "Function not supported" for call logs:
1. Your modem may not support this feature
2. Consider using a different modem model
3. Or contact maintainer for alternative implementation

### SMS Not Receiving

1. Check the add-on logs for "Could not read SMS" messages
2. Test inbox access manually: `gammu -c /tmp/gammurc getallsms` — should list inbound messages, not "Function not supported"
3. If messages arrive but the add-on never publishes them, dump one and compare its format to the fixtures in `tests/parse_sms.bats` — the parser is locked to gammu's English-locale shape
4. If messages accumulate on the SIM/modem instead of being deleted after publish, run `gammu -c /tmp/gammurc getsmsfolders` and confirm folder 1 is SIM memory. The add-on deletes from memory `1`; if your modem stores inbound SMS elsewhere (often `2` = ME), the delete silently fails and dedup catches the re-publish

## Running Tests

The add-on ships with a bats test suite that exercises `lib.sh` against stubbed `gammu` and `mosquitto_pub` binaries. Tests run on the host, no container needed.

```bash
# Install bats once (Debian/Ubuntu)
sudo apt install bats

# Or vendor it locally
git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
/tmp/bats-core/install.sh ~/.local

# Run the suite
bats tests/
```

The suite covers missed-call dedup, SMS sending, SMS-receive plumbing (with fake parsers), the real `parse_sms_dump` / `parse_sms_entry` against realistic `gammu getallsms` fixtures (`tests/parse_sms.bats`), and an end-to-end receive path through `check_received_sms`.

## Technical Details

- **Modem Communication**: Uses `gammu` for all modem operations (call monitoring + SMS sending)
- **Polling Pattern**: Checks for SMS to send (~priority) then polls modem every ~10 seconds
- **Queue System**: File-based queue at `/tmp/sms_queue` for reliable SMS handling
- **No Conflicts**: Only Gammu accesses serial port - eliminates data consumption conflicts
- **Call Detection**: Reads the SIM's MC (Missed Calls) phonebook via `gammu getmemory MC 1 N` each poll (N defaults to 100, the SIM7600 MC capacity). Compares the full positional snapshot to the previous one; publishes entries that shifted in at the top. First poll after restart records a silent baseline so the existing MC backlog doesn't flood Home Assistant. No timestamp is published — gammu's MC entries don't carry one.
- **Deduplication**: `/tmp/processed_calls` stores the last seen MC snapshot. The SIM's MC memory is *not* cleared by the addon — GSM 07.07 says `+CPBW` does not apply to MC storage, and real-world SIMs return "Security error" on delete attempts. FIFO rotation handles overflow.
- **SMS Format**: JSON payload with `number` and `message` fields
- **Status Feedback**: Publishes success/failure status to MQTT after each SMS attempt
- **SMS Receiving**: Polls `gammu getallsms` each cycle; published SMS are deleted from SIM memory. Dedup state lives in `/tmp/processed_sms` keyed by `location_datetime`.
