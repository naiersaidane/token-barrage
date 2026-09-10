---
name: bulk-reader
description: "Délègue les lectures massives de fichiers à un modèle worker bon marché. À utiliser pour lire un fichier de plus de 350 lignes, répondre à une question portant sur 3 fichiers ou plus, ou résumer un gros diff."
---

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/bulk-read --question "<question>" --paths <fichier1> [<fichier2> ...]
```

Chaque appel est indépendant. Pour une question de suivi, rappelle le script avec les
mêmes `--paths` : les fichiers partent chez le worker et n'entrent jamais dans ton
contexte, donc les renvoyer ne te coûte rien.

Vérifie les numéros de ligne et les valeurs exactes avant de t'en servir dans une édition.
