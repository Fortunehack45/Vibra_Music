// A module in the CommonJS shape most indexes publish. It keeps a session token in a top-level
// variable (set during init by a fetch) and reads the host's settings from context.settings.
var session = { token: null };
var tokenPromise = fetch('/session').then(function (r) { return r.json(); }).then(function (j) { session.token = j.token; });

async function searchTracks(query, limit, context) {
  await tokenPromise;
  var res = await fetch('https://api.example.com/search?q=' + encodeURIComponent(query), {
    headers: { 'Authorization': 'Bearer ' + session.token }
  });
  var body = await res.json();
  return {
    total: body.items.length,
    tracks: body.items.slice(0, limit).map(function (item) {
      return {
        id: item.id,
        title: item.title,
        artist: item.artist,
        album: item.album,
        duration: item.seconds,
        audioQuality: item.quality,
        albumCover: 'https://img.example.com/' + item.id + '.jpg'
      };
    })
  };
}

async function getTrackStreamUrl(id, preferredQuality, context) {
  var quality = (context && context.settings && context.settings.quality) ? context.settings.quality.value : preferredQuality;
  var mode = context.settings.fallbackMode.value;
  if (id === 'missing') { return { streamUrl: null }; }
  if (id === 'broken') { throw new Error('backend exploded'); }
  await setTimeout(function () {}, 5);
  return {
    streamUrl: 'https://cdn.example.com/' + id + '.' + (quality === 'LOSSLESS' ? 'flac' : '320.mp3') + '?mode=' + mode + '&atmos=' + context.settings.dolbyAtmos.value,
    track: { id: id, audioQuality: quality === 'LOSSLESS' ? 'FLAC 24-bit / 96 kHz' : '320kbps', bitDepth: quality === 'LOSSLESS' ? 24 : null, sampleRate: quality === 'LOSSLESS' ? 96 : null }
  };
}

module.exports = { searchTracks: searchTracks, getTrackStreamUrl: getTrackStreamUrl };
