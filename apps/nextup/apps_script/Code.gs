/**
 * Next Up: pushes your next few important meetings to pi-api.
 *
 * Script properties (Project Settings → Script Properties):
 *   PUSH_URL         https://<tunnel host>/relay/push/nextup        (required)
 *   PUSH_TOKEN       same value as NEXTUP_TOKEN on the Pi            (required)
 *   RSVP             comma list of YES, MAYBE, INVITED, OWNER        (default YES,OWNER)
 *   RED_ONLY         true / false                                    (default true)
 *   MAX_EVENTS       how many meetings to send                       (default 5)
 *   LOOKAHEAD_HOURS  how far ahead to look                           (default 168)
 *
 * Run installTrigger() once to push every 5 minutes.
 */

const DEFAULTS = {
  RSVP: 'YES,OWNER',
  RED_ONLY: 'true',
  MAX_EVENTS: '5',
  LOOKAHEAD_HOURS: '168',
};

const SKIP_EVENT_TYPES = ['OUT_OF_OFFICE', 'WORKING_LOCATION', 'BIRTHDAY'];

// Hue window (degrees) that counts as "red". Tomato is 0, Flamingo ~5,
// Tangerine ~14 (excluded).
const RED_HUE_MAX = 10;
const RED_HUE_MIN = 345;

// Google's event color palette, keyed by CalendarApp.EventColor id.
const EVENT_COLORS = {
  '1': '#7986CB', // Lavender
  '2': '#33B679', // Sage
  '3': '#8E24AA', // Grape
  '4': '#E67C73', // Flamingo
  '5': '#F6BF26', // Banana
  '6': '#F4511E', // Tangerine
  '7': '#039BE5', // Peacock
  '8': '#616161', // Graphite
  '9': '#3F51B5', // Blueberry
  '10': '#0B8043', // Basil
  '11': '#D50000', // Tomato
};

function pushNextUp() {
  const props = PropertiesService.getScriptProperties();
  const prop = function (key) {
    return props.getProperty(key) || DEFAULTS[key];
  };

  const url = props.getProperty('PUSH_URL');
  const token = props.getProperty('PUSH_TOKEN');
  if (!url || !token) {
    throw new Error('Set the PUSH_URL and PUSH_TOKEN script properties');
  }

  const allowed = prop('RSVP').split(',').map(function (s) {
    return s.trim().toUpperCase();
  });
  const redOnly = prop('RED_ONLY').toLowerCase() === 'true';
  const max = Number(prop('MAX_EVENTS'));
  const now = new Date();
  const end = new Date(now.getTime() + Number(prop('LOOKAHEAD_HOURS')) * 3600 * 1000);

  const cal = CalendarApp.getDefaultCalendar();
  const calColor = cal.getColor();
  const events = [];

  // getEvents includes meetings already in progress; the Tronbyt app decides
  // how long to keep showing those.
  const all = cal.getEvents(now, end);
  for (let i = 0; i < all.length && events.length < max; i++) {
    const ev = all[i];
    if (ev.isAllDayEvent() || SKIP_EVENT_TYPES.indexOf(eventType_(ev)) >= 0) {
      continue;
    }
    const rsvp = String(ev.getMyStatus() || 'OWNER');
    if (allowed.indexOf(rsvp) < 0) {
      continue;
    }
    const color = EVENT_COLORS[ev.getColor()] || calColor;
    if (redOnly && !isRed_(color)) {
      continue;
    }
    events.push({
      title: ev.getTitle(),
      start: iso_(ev.getStartTime()),
      end: iso_(ev.getEndTime()),
      color: color,
      rsvp: rsvp,
    });
  }

  const resp = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: 'application/json',
    headers: { Authorization: 'Bearer ' + token },
    payload: JSON.stringify({ generated_at: iso_(now), events: events }),
    muteHttpExceptions: true,
  });
  const code = resp.getResponseCode();
  if (code !== 204) {
    throw new Error('Push failed: HTTP ' + code + ' ' + resp.getContentText());
  }
}

/** Replaces any existing pushNextUp trigger with one that runs every 5 minutes. */
function installTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'pushNextUp') {
      ScriptApp.deleteTrigger(t);
    }
  });
  ScriptApp.newTrigger('pushNextUp').timeBased().everyMinutes(5).create();
}

function isRed_(hex) {
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || '');
  if (!m) {
    return false;
  }
  const r = parseInt(m[1], 16);
  const g = parseInt(m[2], 16);
  const b = parseInt(m[3], 16);
  const hi = Math.max(r, g, b);
  const lo = Math.min(r, g, b);

  // Red must be the dominant channel and reasonably saturated.
  if (hi !== r || hi - lo < 64) {
    return false;
  }
  let hue = (60 * (g - b)) / (hi - lo);
  if (hue < 0) {
    hue += 360;
  }
  return hue <= RED_HUE_MAX || hue >= RED_HUE_MIN;
}

function eventType_(ev) {
  try {
    return String(ev.getEventType());
  } catch (err) {
    return 'DEFAULT';
  }
}

function iso_(d) {
  return Utilities.formatDate(d, 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
}
