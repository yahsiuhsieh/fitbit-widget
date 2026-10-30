# Validate native Google OAuth before building the data layer

Use a Desktop OAuth client with the system browser, loopback redirect, PKCE, and no embedded client secret. Because Google Health's setup guidance conflicts with Google's native-app security guidance, first validate this flow through `users/me/identity`; adopt the Google Sign-In macOS SDK only if the native flow proves incompatible.
