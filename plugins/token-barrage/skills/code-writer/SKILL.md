---
name: code-writer
description: "Délègue la génération de code répétitif à un modèle worker bon marché. À utiliser pour des tests, de la config, des docstrings, des stubs de types, ou toute génération dont plus de 80 % est prévisible à partir d'un fichier de référence."
---

```bash
# Génère et écrit directement dans le fichier cible
${CLAUDE_PLUGIN_ROOT}/scripts/code-write --spec "<quoi générer>" --reference <fichier-référence> --target <chemin-sortie>

# Sortie sur stdout (sans --target)
${CLAUDE_PLUGIN_ROOT}/scripts/code-write --spec "<quoi générer>" --reference <fichier-référence>
```

Chaque appel est indépendant. Pour enchaîner sur ce qui vient d'être généré, passe ce
fichier en `--reference` de l'appel suivant.

Relis la sortie et fais les retouches chirurgicales sur les 5 à 20 % qui demandent
du jugement.

Ne délègue pas : le débogage, les décisions d'architecture, le code critique.
