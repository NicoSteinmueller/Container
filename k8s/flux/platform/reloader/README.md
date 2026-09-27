# reloader

Startet neu, was ein geändertes Secret benutzt - sonst arbeitet ein Pod nach
einer Rotation mit dem alten Wert weiter.

- **Ein neuer Dienst mit Secret gehört in die Liste**, sonst läuft er nach einer
  Rotation still mit dem alten Wert weiter.
- Die **Gegenseite** ändert Reloader nicht: Ein rotiertes DB-Passwort startet
  die Anwendung neu, die Datenbank kennt aber noch das alte.
