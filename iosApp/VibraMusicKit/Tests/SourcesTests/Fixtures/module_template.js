export const source = `
// a template literal module; an escaped \` backtick in a comment must not end it
async function searchTracks(query, limit) {
  return JSON.stringify({ tracks: [{ id: "t-1", title: "Template Song", artist: query, duration: 61 }], total: 1 });
}
async function getTrackStreamUrl(id) { return { streamUrl: "https://cdn.example.com/" + id + ".m4a" }; }
module.exports = { searchTracks, getTrackStreamUrl };
`