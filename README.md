# GSM MQTT Bridge

This Home Assistant add-on bridges a GSM/cellular modem to MQTT: it publishes missed-call notifications and accepts SMS-sending commands.
The add-on is designed to integrate modem functionality (missed call detection, SMS sending) with Home Assistant.

## Features

- **Modem Event Monitoring**: Detects missed calls from connected GSM modem and publishes to MQTT
- **SMS Sending**: Send SMS messages via MQTT commands from Home Assistant automations
- **Status Feedback**: Publishes SMS delivery status back to MQTT
- **Unified Gammu Architecture**: Single tool for all modem operations - no serial port conflicts
- **Call Deduplication**: Tracks processed calls to avoid duplicate notifications
- **Extensible**: Foundation ready for SMS receiving (future feature)
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
  - `home/gsm_mqtt` - Modem events (missed calls, etc.)
  - `home/gsm_mqtt/sms_status` - SMS delivery status feedback

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
3. Verify your modem supports `getcalllog` (most GSM modems do)
4. Check call log manually: `gammu -c /tmp/gammurc getcalllog`

### Modem Doesn't Support Call Logs

If you see "Function not supported" for call logs:
1. Your modem may not support this feature
2. Consider using a different modem model
3. Or contact maintainer for alternative implementation

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

The suite covers missed-call dedup, SMS sending, and SMS-receive plumbing. When implementing the `parse_sms_dump` / `parse_sms_entry` stubs in `lib.sh`, add a `tests/parse_sms.bats` with real `gammu getallsms` output samples.

## Technical Details

- **Modem Communication**: Uses `gammu` for all modem operations (call monitoring + SMS sending)
- **Polling Pattern**: Checks for SMS to send (~priority) then polls modem every ~10 seconds
- **Queue System**: File-based queue at `/tmp/sms_queue` for reliable SMS handling
- **No Conflicts**: Only Gammu accesses serial port - eliminates data consumption conflicts
- **Call Detection**: Uses `gammu getcalllog` to check for missed calls; the modem's log is intentionally not cleared (would race with incoming calls)
- **Deduplication**: Tracks processed calls in `/tmp/processed_calls` keyed by `number_datetime` so re-reads of the same entry are suppressed and distinct calls within an hour are both reported. The modem's own FIFO rotation keeps its call log bounded.
- **SMS Format**: JSON payload with `number` and `message` fields
- **Status Feedback**: Publishes success/failure status to MQTT after each SMS attempt
- **Extensible**: Ready for SMS receiving implementation (just uncomment function)
