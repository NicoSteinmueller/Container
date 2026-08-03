# Absichtlich leer

Hier liegt die Wurzel, die die FluxInstance aus `../../main.tf` beobachtet
(`sync.path`). Aktuell rollt Flux von hier nichts aus - erster Schritt war nur
Flux selbst und die Status-Seite, im "schrittweise"-Stil des restlichen Repos.

Nächster Schritt: eine `Kustomization`, die z.B. `k8s/whoami` einbindet, kommt
in dieses Verzeichnis.
