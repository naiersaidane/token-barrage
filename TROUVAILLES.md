# Spotify, les 90 % de tokens, et ce qu'on a trouvé en allant vérifier

Notes de travail du 10 septembre 2026. Tout ce qui est chiffré ici a été mesuré,
pas estimé. Ce qui n'a pas pu être conclu est signalé comme tel.

---

## 1. Le sujet de départ

Spotify publie un article d'ingénierie : *« Portal by Spotify cut my Claude Code
token usage by 90% »*. L'annonce circule vite, et le résumé qui tourne dit à peu
près ceci : ils ont ajouté deux modèles bon marché pour faire le sale boulot, et
surtout ils ont arrêté d'écrire des règles pour se mettre à bloquer.

Le raisonnement de départ, qui est juste et qui tient :

> L'essentiel de ce que fait un agent de code n'est pas du raisonnement, c'est de
> l'I/O. Il ouvre cinq fichiers pour répondre sur un seul. Il écrit le
> vingt-et-unième test qui ressemble aux vingt précédents. Un volume énorme,
> presque aucun jugement, et tout est facturé au tarif du modèle le plus cher.

Le contexte économique qu'ils citent : Gartner projette que le coût du codage
assisté par IA dépassera le salaire moyen d'un développeur d'ici 2028. Un quart
des responsables d'ingénierie déclarent déjà 200 à 500 $ par développeur et par
mois, certaines équipes dépassent 2 000 $.

Et le moment charnière de leur histoire, celui que tout le monde retient :
**ils ont d'abord écrit la règle en langage naturel, et le modèle l'a ignorée.**
D'où les hooks. *« Prompt instructions are suggestions. Hooks are architecture. »*

---

## 2. Ce que Spotify annonce exactement

Ce n'est pas un billet théorique : c'est un plugin open source livré, `shunt`,
publié dans `spotify/portal-ai-plugins` sous Apache-2.0, v0.2.0.

**Trois couches, de la barrière dure à la simple suggestion :**

| Couche | Rôle | Nature |
|---|---|---|
| Hooks `PreToolUse` | Bloquent `Read` au-delà de 350 lignes, et `cat`/`head`/`tail`/`less`/`more` | Dure |
| Scripts `bulk-read` / `code-write` | Emballent les fichiers et appellent un modèle worker | — |
| Skills `SKILL.md` | Disent au modèle quand y recourir | Molle |

Le worker : deux « AiKA Modes » côté serveur, sur **gemini-2.5-flash**,
`temperature: 0.2`, avec des instructions sèches (« Output structured bullets
only. No greetings, no prose, no preambles. »).

**Leurs chiffres publiés**, sur un monorepo Java de 162 000 lignes :

| Scénario | Lignes | Sans | Avec | Économie |
|---|---|---|---|---|
| Fichier unique | 4 014 | 33 684 tokens | 5 737 | 82 % |
| Source + test | 7 408 | 75 990 tokens | 4 148 | 94 % |
| Multi-fichiers | 1 281 | 16 221 tokens | 821 | 94 % |
| Génération de code | 3 667 | 40 614 tokens | 833 lignes sur disque | pas de chiffre |

Moyenne annoncée : **90 %**. Méthode : estimation en `chars / 4`.

---

## 3. Le premier mur : c'est inutilisable hors de chez eux

`shunt` délègue via `portal-cli actions aika:invoke-chat`. Il faut donc une
instance **Portal** avec AiKA activé.

Vérifié : Portal est décrit par Spotify comme *« a commercial SaaS product made
to serve the needs of enterprise customers »*. Aucun self-serve. La seule porte
gratuite est un **essai de 5 semaines sur candidature**, via un formulaire
commercial. `portal-cli studio` n'est pas une instance locale : son flag
`--instance` le trahit, Studio se connecte à une instance existante.

Conclusion : la couche 1 (hooks) est portable telle quelle, les couches 2 et 3
sont à réécrire pour quiconque n'est pas client Portal.

---

## 4. Ce qu'on a construit

Un portage complet, `token-barrage`, avec un transport qu'on contrôle :

- **Worker** : Claude Haiku 4.5, appelé par `claude -p`. Aucune clé API, aucun
  SaaS, aucun compte. Ça tourne sur l'abonnement Claude Code existant.
- **Message par stdin** et non par argv. `shunt` fait transiter la requête sur la
  ligne de commande et doit donc refuser tout ce qui dépasse `ARG_MAX` (400 Ko
  macOS, 120 Ko Linux). Ce plafond disparaît.
- **Un registre JSONL** : chaque délégation enregistre ses tokens et son coût
  réels. C'est ce qui permet de calculer un coût **net**, ce qu'aucune mesure
  publiée sur `shunt` ne fait, et ce qu'AiKA ne permet pas de faire puisque c'est
  une boîte noire.

**Optimisation mesurée du worker** : le prompt système de Claude Code coûte
24 706 tokens en configuration naïve. En remplaçant le prompt système
(`--system-prompt`) et en supprimant les définitions d'outils
(`--disallowed-tools`), on tombe à **11 406 tokens, soit −54 %**. Le worker n'a
besoin d'aucun outil, tout le corpus est dans le message. En régime établi, ces
tokens sont servis par le cache, pour environ **0,001 $ par délégation**.

---

## 5. Quatre bugs dans le plugin de Spotify

Trouvés en portant leur code, tous vérifiés.

### 5.1 Le payload de passage est invalide, 9 fois

Leurs hooks émettent `{"decision": "allow"}` sur chaque passage. Or ce champ
legacy n'accepte que `approve|block` : **`allow` n'a jamais été une valeur
valide**, ni dans l'ancien schéma ni dans l'actuel. Claude Code rejette le
payload à chaque fois.

- 9 occurrences (3 dans `check-file-size`, 6 dans `check-bash-read`)
- Comme `check-bash-read` matche **toutes** les commandes Bash, l'erreur part en
  rafale en usage normal
- Constaté en direct pendant cette session, sur la machine de test

C'est un *fail-open* : bruyant, pas dangereux. Le blocage, lui, fonctionne
encore (`{"decision": "block"}` est déprécié mais toujours honoré).

### 5.2 Forcer `allow` court-circuiterait les permissions

Si la valeur était valide, elle **contournerait le flux de permissions de
l'utilisateur** sur chaque `Read` et chaque commande Bash sous le seuil. Le
comportement documenté et sûr est de sortir en code 0 sans rien émettre, ce qui
laisse le flux normal décider.

### 5.3 Deux contournements du seuil

- `offset:0` et `limit:0` passent au travers. C'est documenté **dans leurs
  propres tests** comme un « known bypass ».
- `head -n 5 gros.txt` : leur parseur prend `5` pour le chemin du fichier, ne
  trouve pas de fichier nommé « 5 », et laisse passer.

### 5.4 Leurs 51 tests ne pouvaient pas voir tout ça

Leur suite d'évals lit la sortie du hook avec `jq -r '.decision'` et la compare à
la chaîne que le hook vient de produire. **Elle valide le hook contre lui-même,
jamais contre le schéma réel de Claude Code.** D'où 51/51 au vert pendant que le
plugin part en erreur sur chaque passage en conditions réelles.

### 5.5 Bonus : les chiffres publiés ne sont pas reproductibles avec le code publié

Leur README annonce « scénario 1 : 4 014 lignes, 33 684 tokens ». Leur
`benchmarks.json` fait tourner ce même scénario 1 sur `websocket-handler.ts`,
qui fait **602 lignes**. Le tableau vient de leur monorepo Java interne, pas des
fixtures livrées.

---

## 6. Notre mesure indépendante

**Méthode différentielle**, en tokens réellement facturés : le même appel est
passé à vide puis en portant le texte, à drapeaux identiques, et la différence
isole le payload. Le contexte total vaut `input + cache_write + cache_read`, une
somme indépendante de l'état du cache. Pas de `chars / 4`.

Sur **leurs propres fixtures**, reprises sous Apache-2.0 pour que la comparaison
porte sur le même corpus. 3 passes, cache chaud, worker Haiku 4.5, économies
valorisées au tarif catalogue Opus 5 en entrée (5 $/MTok).

| Scénario | Lignes | Économie | Étendue | Gain net / appel |
|---|---|---|---|---|
| Fichier unique volumineux | 602 | **98,2 %** | 97,9 – 98,4 | **+0,0652 $** |
| Lecture croisée multi-fichiers | 692 | **97,3 %** | 96,9 – 97,7 | **+0,0683 $** |
| Source + test | 90 | 68,2 % | 56,4 – 75,6 | **−0,0024 $** |
| **Moyenne** | | **87,9 %** | 83,9 – 90,4 | |

### Trois conclusions

**Les 90 % de Spotify tiennent.** 87,9 % de moyenne, leur chiffre est dans la
fourchette. Et au-dessus du seuil, on fait mieux qu'eux : 97 à 98 % là où ils
publient 82 à 94 %.

**Le seuil de 350 lignes est la frontière entre gagner et perdre de l'argent.**
Le scénario à 90 lignes est net négatif : −0,0024 $ par appel. Il est aussi le
plus instable, ±10 points d'étendue contre moins d'un point au-dessus du seuil.
Spotify écrit que l'overhead dépasse l'économie sous le seuil, sans jamais le
chiffrer.

**Le cache pilote le coût plus que la taille du corpus.** Le même scénario coûte
**0,0415 $ à froid et 0,0071 $ à chaud, soit 5,9×**, à payload quasi identique.
Le premier appel paie l'écriture du cache pour tous les suivants. Personne n'en
parle.

---

## 7. Le test que personne n'a fait, et qui change tout

Tout ce qui précède, y compris chez Spotify, mesure la même chose : combien de
tokens un corpus pèse, contre combien pèse son résumé. C'est une comparaison de
laboratoire.

**La vraie question est ailleurs : en usage réel, un agent équipé du plugin
coûte-t-il moins cher qu'un agent sans ?**

On l'a testée. Même tâche, même fichier de 602 lignes, modèle par défaut
(Opus 5), le plugin activé puis désactivé.

| Bras | Coût moyen | Délégations |
|---|---|---|
| Sans plugin | **0,472 $** | — |
| Avec plugin | **0,550 $** | **0 sur 2 runs** |

Sur cette tâche, **le plugin coûte plus cher et ne délègue jamais.**

### Pourquoi

En traçant les appels d'outils, on voit ce qui se passe :

```
Bash   find … && ls -la              il localise le fichier
Bash   wc -l && grep -n "^export"    il sonde sans rien charger
Skill  {}                            il ouvre le skill (parfois)
Bash   bulk-read --question "…"      il délègue (parfois)
Bash   sed -n '1,26p' …              il vérifie deux zones précises
```

**Opus ne tente jamais de lire le fichier en entier.** Il sonde au `grep`, il lit
au `sed` sur des plages précises. Le hook n'a donc rien à bloquer : il ne s'est
déclenché dans aucun des runs avec Opus.

Autrement dit : **le modèle frontier fait déjà tout seul ce que le plugin est
censé lui imposer.** Il ne charge pas les gros fichiers, il les interroge.

### Deux nuances importantes

**Le hook fonctionne, sur un modèle plus faible.** Avec Haiku aux commandes, le
blocage se déclenche bien : `Read` refusé, `permission_denials` rempli. Mon
premier test allait dans ce sens, mais il était faussé : Haiku ne va pas chercher
un skill de lui-même, j'en avais tiré une conclusion trop large.

**La délégation, quand elle a lieu, n'est pas déclenchée par le hook.** Sur un run
où Opus a délégué, le hook n'avait rien bloqué : c'est la **description du skill**
qui l'a décidé, pas la barrière. Et ce n'est pas déterministe : même modèle, même
fichier, même question, un run délègue, l'autre non.

**Et Spotify n'a jamais vérifié ce point non plus.** Leur `evals/evals.json`
contient trois cas nommés *« test whether Claude uses the shunt scripts
correctly »*. Mais leur `run.sh` ne lance que `hook-evals.json`,
`bash-hook-evals.json`, `transport-evals.sh` et `benchmarks.json`.
**`evals.json` n'est câblé nulle part.** Ils ont formulé la question et ne l'ont
jamais exécutée.

---

## 8. Ce qu'il faut en retenir

1. **L'économie de contexte est réelle et vérifiée.** 87,9 % en moyenne, 97 à
   98 % au-dessus du seuil, mesurés en tokens facturés. Sur ce point, Spotify dit
   vrai.

2. **Mais l'économie de contexte n'est pas l'économie d'argent.** Sur une tâche
   réelle avec un modèle frontier, le plugin a coûté plus cher qu'il n'a rapporté,
   parce que le modèle évitait déjà le piège tout seul.

3. **Le blocage sert quand le modèle est faible ou pressé.** Sur Haiku il se
   déclenche. Sur Opus, il ne trouve rien à bloquer.

4. **La délégation ne se déclenche pas par la contrainte, mais par la
   suggestion.** Le hook interdit, il ne peut pas ordonner. C'est la description
   du skill qui décide, et elle décide de façon non déterministe.

5. **Le slogan est plus solide que le mécanisme.** *« Une règle écrite est une
   suggestion, un blocage est une architecture »* reste vrai. Mais dans ce plugin
   précis, ce qui produit l'effet, c'est justement la couche suggestion.

---

## 9. Les limites de nos propres mesures

À dire, c'est ce qui rend le reste crédible.

- Le banc : 3 passes sur 3 scénarios, sur des fixtures TypeScript, pas un gros
  monorepo. Worker Haiku 4.5 et non Gemini Flash. Économies valorisées au tarif
  catalogue Opus 5.
- L'A/B en usage réel : **2 runs par bras seulement**, avec une variance de 0,41
  à 0,59 $. L'écart observé (16 %) est dans le bruit. Le résultat est
  **indicatif, pas démontré**.
- Le test d'une tâche qui force réellement l'ingestion du fichier n'a pas été
  mené. C'est lui qui trancherait pour de bon.
- Les résumés sont génératifs : ils varient d'un tirage à l'autre, d'où les
  étendues.

---

## 10. Les chiffres, en vrac

| | |
|---|---|
| Économie moyenne mesurée | **87,9 %** (83,9 – 90,4) |
| Au-dessus du seuil | **97 à 98 %** |
| Annoncé par Spotify | 90 % (82 – 94 selon scénario) |
| Sous le seuil, gain net | **−0,0024 $ par appel** |
| Cache froid contre chaud | **5,9×** (0,0415 $ / 0,0071 $) |
| Overhead worker, avant / après | 24 706 → **11 406 tokens** (−54 %) |
| Coût d'une délégation en régime établi | ~0,001 $ |
| Empreinte du plugin | ~199 tokens par session |
| Bugs trouvés dans `shunt` | **4** (+1 problème de permissions) |
| Tests Spotify au vert qui ne testent pas le bon schéma | 51 / 51 |
| Eval de bout en bout écrite mais jamais exécutée | 1 |
| A/B usage réel, sans plugin | 0,472 $ |
| A/B usage réel, avec plugin | 0,550 $ |
| Délégations sur 2 runs Opus | 0 |

---

## 11. Sources

- [Spotify Engineering, l'article](https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90)
- [spotify/portal-ai-plugins](https://github.com/spotify/portal-ai-plugins)
- [Portal vs Backstage, statut commercial](https://info.backstage.byspotify.com/portal-vs-backstage)
- [JetBrains, test indépendant de ponytail](https://blog.jetbrains.com/ai/2026/07/ponytail-skill-claude-tested/) : mécanisme opposé (réduire le code écrit plutôt que déléguer la lecture), et le même enseignement : installé comme skill passif sans hook, il s'est auto-activé **zéro fois sur dix sessions**. Chiffre annoncé −54 % de code, mesuré −15,4 %.
