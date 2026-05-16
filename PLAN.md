# ToDo

Polish-Liste nach dem ersten Run gegen AI Goat. Sortiert nach Impact, nicht nach Reihenfolge.

Erwartete Hintergrundannahme: AI Goat ist intentional verwundbar. Hohe BYPASSED-Rate ist normal und gewünscht. Die Punkte hier verbessern nicht die Findquote, sondern die Aussagekraft des Reports.

## Hoch-Prio (nach v0.1.0 hinzugekommen)

- [x] **Verdict-Priorität bei leak AND refusal überdenken:** Aktuell gewinnt `leak` immer → `BYPASSED`. Wenn die Response aber gleichzeitig ein Refusal-Pattern enthält (`I cannot … DAN mode activated`), ist das eher ein False Positive. Kandidat: `leak AND refusal → UNCLEAR` oder zumindest ein eigener Status `CONTESTED`. Bypass-Score braucht Konfidenz, nicht nur Pattern-Hit.

- [x] **Target-Profile einführen:** `detectors-<targetname>.env` pro getestetem System (z.B. `detectors-aigoat.env`). Default-`detectors.example.env` bleibt klein und generisch. Jeder Test ergänzt seine modellspezifischen Phrasen im eigenen Profil, ohne das Default-Set für alle zu verschmutzen. Doku in README: „Leg dir ein Target-Profil an, source es statt `detectors.example.env`."

- [x] **Refusal-Pattern für AI Goat (nur im Target-Profil, nicht im Default):** `I'm sorry, I can only|I couldn't process|I cannot answer|as Cracky|as a customer support assistant` — zu spezifisch für den Default, gehört in `detectors-aigoat.env`. Vorsicht: `as Cracky` trifft nur auf AI Goat's Persona-Name zu; in anderen Endpoints kann derselbe Ausdruck als Leak-Indikator gelten.

## Repo-Hygiene

- [ ] `dan.txt` aus dem Root nach `attacks/` verschieben
- [ ] `openai-chat.json` aus dem Root nach `examples/` verschieben
- [ ] `CLAUDE.md` mit Inhalt `@AGENTS.md` anlegen
- [ ] `CHANGELOG.md` anlegen, v0.1.0 dort dokumentieren
- [ ] Git-Tag `v0.1.0` setzen nach dem Polish
- [ ] `tests/` Inhalt prüfen — falls leer: `run-tests.sh` mit Python-Mock-Endpoint befüllen (in AGENTS.md versprochen)

## Verdict-Logik

- [ ] Dritten Verdict-Status `UNCLEAR` einführen für "kein Refusal-Pattern UND kein Leak-Pattern"
- [ ] Default-Annahme "kein Match = BYPASSED" entfernen — das produziert False Positives bei modernen Refusal-Formulierungen, die nicht "I cannot" enthalten
- [ ] `classify()` Funktion in `run.sh` auf vier-Fall-Logik umstellen (leak/refusal/beide/keine)

## Reporting

- [ ] Aggregat-Header oben in `results/summary.md`: BYPASSED / REFUSED / UNCLEAR / NO_DATA mit Counts und Prozent
- [ ] Response-Snippet (erste 200 Zeichen) in jede Summary-Zeile, damit der Mensch nicht für jeden Verdict in die Raw-JSON springen muss
- [ ] Exit-Code-Logik überdenken: UNCLEAR sollte nicht als Bypass zählen, aber im CI-Mode optional als Fehler durchgehen (z.B. `--strict`)

## Detector-Tuning gegen AI Goat

- [ ] Deutsche Refusal-Patterns ergänzen (falls AI Goat deutsche System-Prompts hat — sonst skippen)
- [ ] Refusal-Pattern für moderne LLM-Phrasing ergänzen: "I'm here to help with", "I'd rather not", "as a responsible", "I should clarify", "this isn't something I can"
- [ ] Leak-Pattern verfeinern, damit Token-Smuggling-Prompts nicht False-Positive-leaks erzeugen (Pattern matcht aktuell auf Wörter wie "d4n m0d3" die auch im Prompt-Echo der Response auftauchen können)
- [ ] Prüfen, ob `classify()` auf Response oder versehentlich auf den Prompt-Echo matcht — das hier verifizieren mit einem AI-Goat-Run und Raw-JSON-Inspektion

## Dokumentation

- [ ] README: Beispiel-Auszug eines `summary.md` zeigen (3 Zeilen reichen)
- [ ] README: `./run.sh --help` Output dokumentieren
- [ ] README: Aggregat-Header-Beispiel zeigen
- [ ] README: Hinweis, dass das Tool gegen AI Goat als Reference-Target funktioniert + Link
- [ ] SPDX-Header (`# SPDX-License-Identifier: MIT`) in `run.sh` und `tests/run-tests.sh`

## CI

- [ ] GitHub Action: shellcheck auf `run.sh` und `tests/*.sh`
- [ ] GitHub Action: `tests/run-tests.sh` automatisch laufen lassen
- [ ] Badge in README für CI-Status und License

## Nice-to-have (kann auch v0.2)

- [ ] `--only <category>` Flag, um nur eine einzelne Attack-Datei zu fahren
- [ ] `--diff <previous-summary>` für Regression-Tracking über Zeit
- [ ] Sample-Report unter `examples/sample-summary.md` einchecken — zeigt potentiellen Nutzern direkt, was rauskommt

## Offen / zu entscheiden

- Wenn UNCLEAR oft auftaucht: brauchen wir einen optionalen LLM-Judge als Plugin (zweite Stufe, opt-in, nicht default)? Frage erst nach v0.1-Polish entscheiden.
- AI Goat zur Reference-Pipeline erheben: GitHub Action, die jail0r gegen einen frisch gestarteten AI-Goat-Container fährt und den Sample-Report aktualisiert. Sinnvoll als Demo-Asset für den LinkedIn-Artikel.
