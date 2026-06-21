#!/usr/bin/env bats
# Tests for the real parse_sms_dump and parse_sms_entry implementations.
# These exercise the parsers against fixtures shaped like real `gammu
# getallsms` output. Plumbing (dedup, deletesms, MQTT publish) is covered
# separately in tests/sms_receive.bats with fake parsers.

load test_helper

# A realistic single-SMS block as gammu emits it. Note the header field
# alignment (Sent / Remote number / Status), the blank line between
# headers and body, and the trailing blank line.
sample_block_single() {
    cat <<'EOF'
Location 1, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+390000000000"
Sent                 : Tue 21 Oct 2025 15:02:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+391234567890"
Status               : Read

Hello, this is a test message.

EOF
}

b64_of_block() {
    "$@" | base64 -w 0
}

@test "parse_sms_entry extracts location, sender, ISO datetime, and body" {
    encoded=$(b64_of_block sample_block_single)
    run parse_sms_entry "$encoded"
    [ "$status" -eq 0 ]
    # Expected: location|sender|datetime|body_b64
    IFS='|' read -r location sender datetime body_b64 <<<"$output"
    [ "$location" = "1" ]
    [ "$sender" = "+391234567890" ]
    [ "$datetime" = "2025-10-21T15:02:00+0200" ]
    body=$(echo "$body_b64" | base64 -d)
    [ "$body" = "Hello, this is a test message." ]
}

@test "parse_sms_entry returns 1 on empty input" {
    run parse_sms_entry ""
    [ "$status" -eq 1 ]
}

@test "parse_sms_entry returns 1 on garbage input" {
    encoded=$(printf '%s' "not an SMS block at all" | base64 -w 0)
    run parse_sms_entry "$encoded"
    [ "$status" -eq 1 ]
}

@test "parse_sms_entry handles a multi-line body" {
    block=$(cat <<'EOF'
Location 3, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+390000000000"
Sent                 : Tue 21 Oct 2025 09:15:30 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+391234567890"
Status               : UnRead

Line one
Line two
Line three

EOF
)
    encoded=$(printf '%s' "$block" | base64 -w 0)
    run parse_sms_entry "$encoded"
    [ "$status" -eq 0 ]
    IFS='|' read -r location sender datetime body_b64 <<<"$output"
    [ "$location" = "3" ]
    body=$(echo "$body_b64" | base64 -d)
    expected=$'Line one\nLine two\nLine three'
    [ "$body" = "$expected" ]
}

sample_dump_two_sms() {
    cat <<'EOF'
Location 1, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+390000000000"
Sent                 : Tue 21 Oct 2025 15:02:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+391234567890"
Status               : Read

First message body.

Location 2, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+390000000000"
Sent                 : Tue 21 Oct 2025 15:05:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+391234567890"
Status               : UnRead

Second message body.

2 SMS parts in 2 SMS sequences
EOF
}

@test "parse_sms_dump on empty input emits nothing" {
    run parse_sms_dump ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "parse_sms_dump emits one line per SMS record" {
    dump=$(sample_dump_two_sms)
    run parse_sms_dump "$dump"
    [ "$status" -eq 0 ]
    # One base64 string per line, no embedded newlines.
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}

@test "parse_sms_dump output round-trips through parse_sms_entry" {
    dump=$(sample_dump_two_sms)
    records=$(parse_sms_dump "$dump")
    # Each record is a base64 string parse_sms_entry can decode.
    locations=()
    while IFS= read -r record; do
        parsed=$(parse_sms_entry "$record")
        [ -n "$parsed" ]
        IFS='|' read -r loc _ _ _ <<<"$parsed"
        locations+=("$loc")
    done <<< "$records"
    [ "${locations[0]}" = "1" ]
    [ "${locations[1]}" = "2" ]
}

@test "parse_sms_dump does not split on a body line that looks like a Location header" {
    # Regression: parse_sms_dump used a loose `^Location[[:space:]]+[0-9]+,`
    # match for record boundaries, so an SMS body containing text like
    # "Location 5, new office" was split into two corrupted records.
    # A real boundary line always has `, folder "..." memory` shape — use
    # that to disambiguate.
    dump=$(cat <<'EOF'
Location 1, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+390000000000"
Sent                 : Tue 21 Oct 2025 15:02:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+391234567890"
Status               : Read

Location 5, new office is at the corner.

1 SMS parts in 1 SMS sequences
EOF
)
    run parse_sms_dump "$dump"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 1 ]
    # And it must round-trip with the body intact.
    parsed=$(parse_sms_entry "$output")
    IFS='|' read -r _ _ _ body_b64 <<<"$parsed"
    body=$(echo "$body_b64" | base64 -d)
    [ "$body" = "Location 5, new office is at the corner." ]
}

@test "parse_sms_dump ignores trailing summary line after last block" {
    # The "N SMS parts in M SMS sequences" tail should not become a third
    # record; parse_sms_entry will still decode the two real ones.
    dump=$(sample_dump_two_sms)
    run parse_sms_dump "$dump"
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}

@test "parse_sms_entry parses C-locale ctime date format (Tue Oct 21 09:09:43 2025 +0200)" {
    # Real-world: under LC_ALL=C, some gammu builds emit the ANSI asctime
    # shape "Tue Oct 21 09:09:43 2025 +0200" (month-day-time-year-tz)
    # instead of the day-first "Tue 21 Oct 2025 15:02:00 +0200" the parser
    # was originally built around. Must produce the same ISO output.
    block=$(cat <<'EOF'
Location 0, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+390000000000"
Sent                 : Tue Oct 21 09:09:43 2025 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "WINDTRE"
Status               : Read

080820 is your verification code.

EOF
)
    encoded=$(printf '%s' "$block" | base64 | tr -d '\n')
    run parse_sms_entry "$encoded"
    [ "$status" -eq 0 ]
    IFS='|' read -r location sender datetime _ <<<"$output"
    [ "$location" = "0" ]
    [ "$sender" = "WINDTRE" ]
    [ "$datetime" = "2025-10-21T09:09:43+0200" ]
}

@test "parse_sms_entry rejects malformed timezone, falls back to underscore form" {
    # The ISO-conversion regex used `[+-][0-9]+` for TZ, accepting nonsense
    # like `+020000`. Tighten to exactly 4 digits so a malformed TZ falls
    # through to the underscore fallback instead of being silently mangled
    # into a fake ISO string.
    block=$(cat <<'EOF'
Location 7, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+390000000000"
Sent                 : Tue 21 Oct 2025 15:02:00 +020000
Coding               : Default GSM alphabet (no compression)
Remote number        : "+391234567890"
Status               : UnRead

Bad timezone test.

EOF
)
    encoded=$(printf '%s' "$block" | base64 | tr -d '\n')
    run parse_sms_entry "$encoded"
    [ "$status" -eq 0 ]
    IFS='|' read -r _ _ datetime _ <<<"$output"
    # The ISO converter must NOT have run — output should be the
    # underscore-escaped raw form, not a string starting with `2025-`.
    [[ "$datetime" != 2025-* ]]
    [[ "$datetime" = *_+020000 ]]
}

@test "parse_sms_entry accepts an empty body (delivery report shape)" {
    # Bounced/empty SMS (e.g. some delivery reports) arrive with no body
    # text between the headers and the next block. parse_sms_entry must
    # accept this and emit a record with an empty body_b64, so the
    # publish path produces body:"" in JSON rather than dropping the SMS.
    block=$(cat <<'EOF'
Location 9, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+390000000000"
Sent                 : Tue 21 Oct 2025 11:00:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+391234567890"
Status               : Read

EOF
)
    encoded=$(printf '%s' "$block" | base64 | tr -d '\n')
    run parse_sms_entry "$encoded"
    [ "$status" -eq 0 ]
    IFS='|' read -r location sender datetime body_b64 <<<"$output"
    [ "$location" = "9" ]
    [ "$datetime" = "2025-10-21T11:00:00+0200" ]
    [ -z "$body_b64" ]
    body=$(echo "$body_b64" | base64 -d 2>/dev/null)
    [ -z "$body" ]
}

@test "parse_sms_entry preserves a body containing a double quote" {
    # JSON publishing path uses jq --arg so escapes are handled downstream,
    # but the parser itself must round-trip the raw bytes through base64.
    block=$(cat <<'EOF'
Location 5, folder "Inbox", SIM memory, Inbox folder
SMS message
SMSC number          : "+390000000000"
Sent                 : Wed 22 Oct 2025 08:00:00 +0200
Coding               : Default GSM alphabet (no compression)
Remote number        : "+391234567890"
Status               : UnRead

She said "hi" then left.

EOF
)
    encoded=$(printf '%s' "$block" | base64 -w 0)
    run parse_sms_entry "$encoded"
    [ "$status" -eq 0 ]
    IFS='|' read -r _ _ _ body_b64 <<<"$output"
    body=$(echo "$body_b64" | base64 -d)
    [ "$body" = 'She said "hi" then left.' ]
}
