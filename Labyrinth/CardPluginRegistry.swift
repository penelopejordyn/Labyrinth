import CoreGraphics
import Foundation

enum WebCardSource {
    case htmlString(String)
    case file(url: URL, readAccessURL: URL)
}

struct CardPluginDefinition {
    let typeID: String
    let name: String
    let defaultSizePt: CGSize
    let defaultPayload: Data
    let webSource: WebCardSource
}

final class CardPluginRegistry {
    static let shared = CardPluginRegistry()

    private var definitionsByTypeID: [String: CardPluginDefinition] = [:]

    private init() {
        #if DEBUG
        register(.sampleHello)
        #endif
    }

    func register(_ definition: CardPluginDefinition) {
        definitionsByTypeID[definition.typeID] = definition
    }

    func definition(for typeID: String) -> CardPluginDefinition? {
        definitionsByTypeID[typeID]
    }

    var allDefinitions: [CardPluginDefinition] {
        Array(definitionsByTypeID.values).sorted { $0.typeID < $1.typeID }
    }
}

extension CardPluginDefinition {
    static var sampleHello: CardPluginDefinition {
        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>Hello</title>
            <style>
              :root { color-scheme: dark; }
              body { margin: 0; font-family: -apple-system, system-ui; background: #111; color: #fff; }
              .wrap { padding: 12px; }
              button { padding: 10px 12px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.2); background: rgba(255,255,255,0.08); color: #fff; }
              .row { display: flex; gap: 10px; align-items: center; }
              .muted { opacity: 0.7; font-size: 12px; }
              pre { white-space: pre-wrap; word-break: break-word; background: rgba(255,255,255,0.06); padding: 10px; border-radius: 10px; }
            </style>
          </head>
          <body>
            <div class="wrap">
              <div class="row">
                <button id="inc">Increment</button>
                <div class="muted">Sample web card (CSC push/events only)</div>
              </div>
              <pre id="state">{}</pre>
            </div>
            <script>
              let state = { count: 0 };
              const stateEl = document.getElementById("state");
              const render = () => { stateEl.textContent = JSON.stringify(state, null, 2); };
              render();

              window.__labyrinth?.onHostMessage?.((msg) => {
                if (!msg || msg.type !== "init") return;
                if (msg.payload && msg.payload.payloadJSON) {
                  state = msg.payload.payloadJSON;
                  render();
                }
              });

              document.getElementById("inc").addEventListener("click", () => {
                state.count = (state.count || 0) + 1;
                render();
                window.__labyrinth?.emit?.({ type: "setPayload", payload: state });
              });
            </script>
          </body>
        </html>
        """

        return CardPluginDefinition(
            typeID: "labyrinth.sample.hello",
            name: "Hello",
            defaultSizePt: CGSize(width: 360, height: 220),
            defaultPayload: Data("{\"count\":0}".utf8),
            webSource: .htmlString(html)
        )
    }
}

