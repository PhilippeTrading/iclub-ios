# Consignes pour toute session de développement sur l'app iOS

Lire le [README](README.md), puis la [norme de commentaires](docs/NORME-COMMENTAIRES.md). La méthode de travail, le registre des travaux et la documentation d'ensemble (base de données, défauts connus) sont dans le dépôt `iclub-web` (`docs/`).

- **Tout code écrit ou modifié est commenté en détail selon la norme, dans le même commit** : `///` sur chaque type, propriété, fonction et vue, `// MARK: -` pour les sections, un commentaire pour chaque étape et chaque règle. L'app est préparée pour une revente : elle doit pouvoir être reprise sans ceux qui l'ont écrite.
- Chaque prompt écrit pour Claude dans Xcode rappelle cette norme.
- L'app écrit directement dans la base Supabase, unique et partagée avec le web et les vrais clubs : une règle qui doit valoir pour tous vit dans la base (RLS, déclencheurs, fonctions), pas seulement dans l'app.
- Jamais de clé de service dans l'app.
- Une modification non commitée qui n'est pas la tienne appartient à quelqu'un : travailler dans un worktree à côté, ne jamais la remiser ni l'écraser.
- Chaque travail a son numéro D dans le registre d'`iclub-web` ; ses commits portent `[Dn]`.
- Textes : pas de tiret cadratin ni demi-cadratin comme ponctuation, pas d'emoji, aucune mention d'intelligence artificielle.
