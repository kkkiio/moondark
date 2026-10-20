///|
/// Build the provider's authorization URL for the Authorization Code Flow
/// (RFC 6749 Section 4.1) with PKCE `S256` (RFC 7636).
///
/// The caller generates and persists `state` (CSRF token) and
/// `code_verifier` (PKCE secret) in the user's session before redirecting
/// the user-agent to the returned URL.
pub fn Provider::authorize_url(
  self : Self,
  state~ : String,
  code_verifier~ : String,
  nonce~ : String = "",
) -> String {
  ignore((self, state, code_verifier, nonce))
  abort("todo")
}

///|
/// Exchange an authorization `code` at the provider's token endpoint over
/// HTTPS and resolve the authenticated user's `Identity`.
///
/// ### Why no JWKS / RS256 signature verification is required
///
/// Per **OpenID Connect Core 1.0, Section 3.1.3.7 (ID Token Validation),
/// Rule 6**:
/// > If the ID Token is received via direct communication between the Client
/// > and the Token Endpoint (which it is in this flow), the TLS server
/// > validation MAY be used to validate the issuer in place of checking the
/// > token signature.
///
/// Because the backend exchanges `code` directly with the provider's HTTPS
/// `token_url` (e.g. `https://oauth2.googleapis.com/token`), TLS already
/// authenticates the issuer. For OIDC providers (such as Google), we only
/// need to Base64URL-decode the `id_token` payload and verify the claims
/// (`iss`, `aud == client_id`, `exp > now`, and optional `nonce`), avoiding
/// heavy RSA/JWKS cryptographic dependencies. For pure OAuth2 providers
/// without `id_token` (such as GitHub), `access_token` is used to query
/// `userinfo_url` over HTTPS.
pub async fn Provider::authenticate(
  self : Self,
  code~ : String,
  code_verifier~ : String,
  nonce~ : String = "",
) -> Identity raise OAuthError {
  ignore((self, code, code_verifier, nonce))
  abort("todo")
}

///|
/// Generate a cryptographically random URL-safe token suitable for CSRF
/// `state`, PKCE `code_verifier`, or OIDC `nonce`.
pub fn generate_token() -> String raise OAuthError {
  abort("todo")
}

///|
/// OAuth 2.0 / OIDC provider configuration.
pub(all) struct Provider {
  /// Stable provider identifier stored in `CredentialModel.provider`
  /// (e.g. `"google"`, `"github"`).
  name : String
  client_id : String
  client_secret : String
  redirect_uri : String
  auth_url : String
  token_url : String
  /// Optional OIDC expected `iss` claim (e.g. `"https://accounts.google.com"`).
  /// When non-empty, `authenticate` extracts identity from the token
  /// response's `id_token` and validates its claims per OIDC Core 3.1.3.7.
  issuer : String
  /// Optional UserInfo endpoint for non-OIDC providers (e.g. GitHub).
  userinfo_url : String
  scopes : Array[String]
} derive(Debug, Eq)

///|
pub extend Provider with Debug::{to_repr}

///|
pub extend Provider with Eq::{equal, not_equal}

///|
/// Preconfigured Google OIDC provider (`openid`, `email`, `profile`).
pub fn Provider::google(
  client_id~ : String,
  client_secret~ : String,
  redirect_uri~ : String,
  scopes~ : Array[String] = ["openid", "email", "profile"],
) -> Provider {
  Provider::{
    name: "google",
    client_id,
    client_secret,
    redirect_uri,
    auth_url: "https://accounts.google.com/o/oauth2/v2/auth",
    token_url: "https://oauth2.googleapis.com/token",
    issuer: "https://accounts.google.com",
    userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
    scopes,
  }
}

///|
/// Verified third-party identity returned by `Provider::authenticate`,
/// ready to pass into `@auth.Auth::authenticate_oauth`, `register_oauth`,
/// or `bind_oauth`.
pub(all) struct Identity {
  /// Matches `Provider.name` (e.g. `"google"`).
  provider : String
  /// Provider-scoped stable subject identifier (`sub` claim in OIDC).
  sub : String
  email : String?
  email_verified : Bool
  display_name : String
  /// Raw token response (`access_token`, optional `refresh_token`, etc.).
  tokens : TokenResponse
} derive(Debug, Eq)

///|
pub extend Identity with Debug::{to_repr}

///|
pub extend Identity with Eq::{equal, not_equal}

///|
/// OAuth 2.0 token endpoint response (RFC 6749 Section 5.1).
pub(all) struct TokenResponse {
  access_token : String
  token_type : String
  expires_in : Int64?
  refresh_token : String?
  scope : String?
  id_token : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub extend TokenResponse with Debug::{to_repr}

///|
pub extend TokenResponse with Eq::{equal, not_equal}

///|
pub extend TokenResponse with ToJson::{to_json}

///|
pub extend TokenResponse with FromJson::{from_json}

///|
/// Errors raised during the OAuth 2.0 / OIDC handshake and validation.
pub(all) suberror OAuthError {
  EntropyUnavailable
  TokenExchangeFailed(Int32, String)
  InvalidTokenResponse(String)
  InvalidIdToken(String)
  ClaimMismatch(String)
  TokenExpired(Int64, Int64)
  UserInfoFailed(Int32, String)
} derive(Debug, Eq)

///|
pub extend OAuthError with Debug::{to_repr}

///|
pub extend OAuthError with Eq::{equal, not_equal}
