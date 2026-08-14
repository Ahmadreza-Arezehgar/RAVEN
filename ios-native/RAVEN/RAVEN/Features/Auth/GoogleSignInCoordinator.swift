// GoogleSignInCoordinator was removed in the serverless pivot.
//
// RAVEN no longer has any server or account system — identity is purely
// key-based and local, so there is no OAuth / Google Sign-In flow and
// nothing imports the GoogleSignIn SDK anymore. The previous coordinator
// (and its GoogleCredential / GoogleSignInError types) had no callers and
// was deleted along with the GIDSignIn URL-callback branch in RAVENApp.swift.
