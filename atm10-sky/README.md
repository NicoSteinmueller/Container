# ATM10 To the Sky

Minecraft-Server für [All the Mods 10: To the Sky](https://www.curseforge.com/minecraft/modpacks/all-the-mods-10-sky)
(1.21.1, NeoForge) mit `itzg/minecraft-server`. Das Image lädt das Pack beim Start
über `TYPE: AUTO_CURSEFORGE` selbst; Client-Mods filtert es heraus.


### Bestehende Welt importieren
 Die Welt **vor dem ersten Start** als `world/` ins Datenverzeichnis
legen.

Voraussetzungen:
- Die Welt stammt aus derselben Pack-Version wie `CF_FILENAME_MATCHER`

## Ressourcen

10 GiB Heap, Container-Limit 18 GiB. 

Neben dem Heap belegt die JVM schon direkt nach dem Start rund 2,7 GB für Metaspace,
Code-Cache, GC-Strukturen und native Puffer. Der
Rest des Limits bleibt Puffer für Wachstum und den Page Cache, der bei Docker
mitzählt.
