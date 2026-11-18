/**
 * Messages for the portfolio auth flow (replaces ra-supabase-language-*). Also corrects upstream
 * strings that promise emails: this deployment has no email service, links are shown instead.
 */
export const portfolioEnglishMessages = {
  crm: {
    auth: {
      forgot_password: "Forgot your password?",
      forgot_password_details:
        "Ask an administrator of this CRM for a password reset link. The link is valid for one hour and can be used once.",
      back_to_login: "Back to sign in",
      choose_password: "Choose your password",
      password_rules: "At least 12 characters.",
      password_mismatch: "Passwords do not match",
      password_set: "Password saved. Please sign in.",
      missing_token: "This page needs the one-time link you received. Ask an administrator for a new link.",
      invitation_link_title: "Invitation link",
      reset_link_title: "Password reset link",
      one_time_link_details:
        "Send this one-time link to %{name} through a channel you trust. It lets them choose a password and expires on %{expires}. It is shown only once.",
      the_user: "the user",
      copy_link: "Copy link",
      copied: "Copied",
      password_link: "Password link",
    },
    profile: {
      password_reset_sent: "Choose your new password.",
    },
    showcase: {
      explore: "Explore the live demo (read-only)",
      explore_hint: "Fictional company and simulated activity. No sign-up needed.",
      banner: "Read-only demo · fictional data, live simulated activity · changes are disabled",
    },
  },
  resources: {
    sales: {
      create: {
        success: "User created. Share the one-time invitation link with them.",
      },
    },
  },
};

export const portfolioFrenchMessages = {
  crm: {
    auth: {
      forgot_password: "Mot de passe oublié ?",
      forgot_password_details:
        "Demandez à un administrateur de ce CRM un lien de réinitialisation. Le lien est valable une heure et ne peut servir qu'une fois.",
      back_to_login: "Retour à la connexion",
      choose_password: "Choisissez votre mot de passe",
      password_rules: "Au moins 12 caractères.",
      password_mismatch: "Les mots de passe ne correspondent pas",
      password_set: "Mot de passe enregistré. Veuillez vous connecter.",
      missing_token: "Cette page nécessite le lien à usage unique reçu. Demandez un nouveau lien à un administrateur.",
      invitation_link_title: "Lien d'invitation",
      reset_link_title: "Lien de réinitialisation",
      one_time_link_details:
        "Transmettez ce lien à usage unique à %{name} par un canal de confiance. Il permet de choisir un mot de passe et expire le %{expires}. Il n'est affiché qu'une fois.",
      the_user: "l'utilisateur",
      copy_link: "Copier le lien",
      copied: "Copié",
      password_link: "Lien de mot de passe",
    },
    profile: {
      password_reset_sent: "Choisissez votre nouveau mot de passe.",
    },
    showcase: {
      explore: "Explorer la démo en direct (lecture seule)",
      explore_hint: "Entreprise fictive et activité simulée. Aucune inscription nécessaire.",
      banner: "Démo en lecture seule · données fictives, activité simulée en direct · modifications désactivées",
    },
  },
  resources: {
    sales: {
      create: {
        success: "Utilisateur créé. Transmettez-lui le lien d'invitation à usage unique.",
      },
    },
  },
};
