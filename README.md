# YouTube Radio for Omarchy

Lecteur audio et radio en tâche de fond pour Omarchy Linux. Écoutez vos lives YouTube préférés (comme les radios 24/7 ou Lofi Girl) et n'importe quelle vidéo ou mix audio en arrière-plan sans charger de flux vidéo, avec une consommation CPU/RAM quasi nulle.

## Fonctionnalités

- **Audio en arrière-plan** : utilise `mpv --no-video` et `yt-dlp` en arrière-plan via PipeWire.
- **Support des Lives YouTube & Radios 24/7** : résolution automatique et dynamique des lives de chaînes.
- **Boutons Préréglages (1-clic)** :
  - **EverPop 7080** : Radio pop coréenne 7080 live
  - **Lofi Girl** : Flux radio live 24/7 lofi hip hop
- **Contrôles transport complets** : Lecture, Pause, Reprendre, Arrêter, Couper le son, Curseur de volume.
- **Historique** des 10 dernières vidéos ou stations jouées.
- **Pilotage en ligne de commande (IPC)** via `omarchy-shell`.
- **Raccourcis clavier** dans le panneau :
  - `1` : Lancer la radio EverPop 7080
  - `2` : Lancer la radio Lofi Girl
  - `Espace` / `p` : Lecture / Pause
  - `m` : Couper / rétablir le son
  - `s` : Arrêter
  - `u` : Éditer l'URL
  - `r` : Ouvrir l'historique
  - `Échap` : Fermer le panneau

## Prérequis

- Arch Linux / Omarchy
- `mpv`
- `yt-dlp`

```bash
omarchy pkg add mpv yt-dlp
```

## Installation

Activez le plugin dans Omarchy :

```bash
omarchy plugin enable promaa.youtube-radio --section right
```

## Commandes en ligne de commande (CLI / IPC)

```bash
# Lancer un préréglage
omarchy-shell youtube-radio preset everpop
omarchy-shell youtube-radio preset lofigirl

# Lancer une URL ou vidéo
omarchy-shell youtube-radio play "https://www.youtube.com/watch?v=D4H7ItMDIGU"

# Contrôles de transport
omarchy-shell youtube-radio toggle             # Démarrer ou arrêter
omarchy-shell youtube-radio pause toggle       # Pause / reprise
omarchy-shell youtube-radio mute toggle        # Couper / rétablir le son
omarchy-shell youtube-radio volume 40          # Régler le volume (0-100)
omarchy-shell youtube-radio stop

# État
omarchy-shell youtube-radio status
```

## Licence

MIT
