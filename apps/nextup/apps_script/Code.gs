/**
 * Next Up: pushes your next few important meetings to pi-api.
 *
 * Script properties (Project Settings → Script Properties):
 *   PUSH_URL         https://<tunnel host>/relay/push/nextup        (required)
 *   PUSH_TOKEN       same value as NEXTUP_TOKEN on the Pi            (required)
 *   RSVP             comma list of YES, MAYBE, INVITED, OWNER        (default YES,OWNER)
 *   COLORS           comma list of red, green; or "any"              (default red,green)
 *   MAX_EVENTS       how many meetings to send                       (default 5)
 *   LOOKAHEAD_HOURS  how far ahead to look                           (default 168)
 *
 * If the tunnel host is behind Cloudflare Access, also set the service
 * token (sent as CF-Access-Client-Id / CF-Access-Client-Secret):
 *   CF_ACCESS_CLIENT_ID
 *   CF_ACCESS_CLIENT_SECRET
 *
 * Run installTrigger() once to push every 5 minutes.
 */

const DEFAULTS = {
  RSVP: 'YES,OWNER',
  COLORS: 'red,green',
  MAX_EVENTS: '5',
  LOOKAHEAD_HOURS: '168',
};

const SKIP_EVENT_TYPES = ['OUT_OF_OFFICE', 'WORKING_LOCATION', 'BIRTHDAY'];

// Hue windows (degrees) for each color family. A window with min > max wraps
// through 0.
//   red:   Tomato 0, Flamingo ~5. Tangerine ~14 is excluded (orange).
//   green: Pistachio ~89, Basil ~149, Sage ~152. Avocado ~64 (yellow-green)
//          and Eucalyptus ~174 (teal) are excluded.
const HUE_FAMILIES = {
  red: { min: 345, max: 10 },
  green: { min: 80, max: 165 },
};

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
  const colors = prop('COLORS').toLowerCase().split(',').map(function (s) {
    return s.trim();
  });
  const anyColor = colors.indexOf('any') >= 0;
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
    if (!anyColor && colors.indexOf(hueFamily_(color)) < 0) {
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
    headers: pushHeaders_(props, token),
    payload: JSON.stringify({ generated_at: iso_(now), events: events }),
    muteHttpExceptions: true,
  });
  const code = resp.getResponseCode();
  if (code !== 204) {
    throw new Error('Push failed: HTTP ' + code + ' ' + resp.getContentText());
  }
}

function pushHeaders_(props, token) {
  const headers = { Authorization: 'Bearer ' + token };
  const cfId = props.getProperty('CF_ACCESS_CLIENT_ID');
  const cfSecret = props.getProperty('CF_ACCESS_CLIENT_SECRET');
  if (cfId && cfSecret) {
    headers['CF-Access-Client-Id'] = cfId;
    headers['CF-Access-Client-Secret'] = cfSecret;
  }
  return headers;
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

/** Returns the HUE_FAMILIES key a hex color falls in, or null. */
function hueFamily_(hex) {
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || '');
  if (!m) {
    return null;
  }
  const r = parseInt(m[1], 16);
  const g = parseInt(m[2], 16);
  const b = parseInt(m[3], 16);
  const hi = Math.max(r, g, b);
  const lo = Math.min(r, g, b);

  // Greys and washed-out colors have no meaningful hue.
  if (hi - lo < 64) {
    return null;
  }
  let hue;
  if (hi === r) {
    hue = (60 * (g - b)) / (hi - lo);
  } else if (hi === g) {
    hue = 120 + (60 * (b - r)) / (hi - lo);
  } else {
    hue = 240 + (60 * (r - g)) / (hi - lo);
  }
  if (hue < 0) {
    hue += 360;
  }
  for (const name in HUE_FAMILIES) {
    const w = HUE_FAMILIES[name];
    const inside = w.min <= w.max ? hue >= w.min && hue <= w.max : hue >= w.min || hue <= w.max;
    if (inside) {
      return name;
    }
  }
  return null;
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
