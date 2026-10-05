# Mac Aero Agents (6.3.8)

Mac 6.3.8 clients use `POST /v1/desktop/agents`. Earlier clients and Android
keep their existing endpoints. Provider credentials stay inside the Worker.

- Model: GPT-6 Luna. Ordinary chat uses `none` reasoning; research, fact-check
  and YouTube/Creator Tools use `medium`.
- OpenAI built-in live web search runs inside the session. Spectra is an explicit
  visible search or last-resort browser tool, not the default research pipeline.
- Explicit Research mode opens the sourced Research, wrapped. page after the
  answer with Aero open for follow-ups; ordinary web searches stay in chat.
  Requests from the new-tab input open full-window chat while working.
- Browser tools are typed functions: open/read/look, click/type, reminder,
  opt-in browser context and Spectra search. Only pending required actions run;
  call IDs cache results so polling does not repeat browser actions.
- History, bookmarks and other tabs are requested on demand and honor Settings.
  Explicit attachments are sent with the request. The current page is read only
  through its tool. Displayed result pills reflect attachments or executed tools.
- Signed session handles bind the provider session to its client ID and expire
  after 30 minutes. The signing key stays server-side. Arbitrary session IDs are
  never accepted from clients.
- The SSE connection supplies real progress. Polling checks completed turn state
  and recovers progress stream disconnections. Commentary and reasoning are not
  treated as final answers. Source links come from annotations or answer Markdown.
- Stop cancels the current native task and sends provider cancellation; terminal
  requests delete their provider session. Tool runs stop between actions.
- A fresh provider session receives the bounded conversation transcript for each
  user request. Do not silently repeat session creation after an ambiguous error.

Use one isolated BreezeTest build with its own profile. Preview `.test` bundles
default to `BreezeTest` data; main Breeze retains its existing data directory.
This document describes implementation, not release or full QA acceptance.

## Preview checks

- Live Agents requests completed with `none` for chat and `medium` for research;
  built-in search and typed browser-tool continuation were exercised.
- BreezeTest showed streamed Searching/Writing stages, clickable NASA sources,
  Research, wrapped. alongside Aero, and a follow-up retained the research context.
- Stop restored the input; stopped/failed research clears its summary flag.
- A PNG input completed through the live desktop route with the expected color.
- Creator Tools retrieved the real transcript and opened its completed breakdown
  in a split beside the video. Snapshot callbacks have a five-second timeout so
  a stalled video snapshot cannot block the request.
- 6.3.8 packages this verified Mac implementation. Android endpoints stay
  on their existing implementation.
