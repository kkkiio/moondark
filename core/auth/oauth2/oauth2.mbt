///|
/// Build the provider's authorization URL for the Authorization Code Flow
/// (RFC 6749 Section 4.1). Pass a `code_verifier` to opt into PKCE `S256`
/// (RFC 7636) and a `nonce` for OIDC replay protection; empty strings
/// leave both out, matching allauth's defaults.
///
/// The caller generates and persists `state` (CSRF token), `nonce` and
/// `code_verifier` in the user's session before redirecting the
/// user-agent to the returned URL.
pub fn Provider::authorize_url(
  self : Self,
  state~ : String,
  code_verifier~ : String = "",
  nonce~ : String = "",
) -> String {
  let url = StringBuilder()
  url.write_string(self.auth_url)
  url.write_char('?')
  url.write_string("response_type=code&client_id=")
  url.write_string(@percent.encode(self.client_id, escape_chars=query_escapes))
  url.write_string("&redirect_uri=")
  url.write_string(
    @percent.encode(self.redirect_uri, escape_chars=query_escapes),
  )
  url.write_string("&scope=")
  url.write_string(
    @percent.encode(self.scopes.join(" "), escape_chars=query_escapes),
  )
  url.write_string("&state=")
  url.write_string(@percent.encode(state, escape_chars=query_escapes))
  if nonce != "" {
    url.write_string("&nonce=")
    url.write_string(@percent.encode(nonce, escape_chars=query_escapes))
  }
  if code_verifier != "" {
    url.write_string("&code_challenge=")
    url.write_string(
      b64url(
        @crypto.sha256(@utf8.encode(code_verifier)).unsafe_reinterpret_as_bytes(),
      ),
    )
    url.write_string("&code_challenge_method=S256")
  }
  url.to_string()
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
  code_verifier~ : String = "",
  nonce~ : String = "",
) -> Identity raise OAuthError {
  // Exchange the authorization code at the token endpoint (RFC 6749 4.1.3).
  let form = StringBuilder()
  form.write_string("grant_type=authorization_code&code=")
  form.write_string(@percent.encode(code, escape_chars=query_escapes))
  form.write_string("&redirect_uri=")
  form.write_string(
    @percent.encode(self.redirect_uri, escape_chars=query_escapes),
  )
  form.write_string("&client_id=")
  form.write_string(@percent.encode(self.client_id, escape_chars=query_escapes))
  form.write_string("&client_secret=")
  form.write_string(
    @percent.encode(self.client_secret, escape_chars=query_escapes),
  )
  if code_verifier != "" {
    form.write_string("&code_verifier=")
    form.write_string(
      @percent.encode(code_verifier, escape_chars=query_escapes),
    )
  }
  let (response, data) = @http.post(self.token_url, form.to_string(), headers={
    "Content-Type": "application/x-www-form-urlencoded",
    "Accept": "application/json",
  }) catch {
    e =>
      raise TokenExchangeFailed(0, "token endpoint unreachable", cause=Some(e))
  }
  let text = data.text() catch {
    e => raise TokenExchangeFailed(response.code, "", cause=Some(e))
  }
  guard response.code == 200 else {
    raise TokenExchangeFailed(response.code, text, cause=None)
  }
  let tokens : TokenResponse = @json.from_json(
    @json.parse(text) catch {
      _ => raise InvalidTokenResponse(text)
    },
  ) catch {
    _ => raise InvalidTokenResponse(text)
  }
  // OIDC providers (issuer set) answer who the user is in the id_token;
  // everyone else needs a userinfo round-trip with the access token.
  let claims = if self.issuer != "" {
    guard tokens.id_token is Some(id_token) else {
      raise InvalidTokenResponse("missing id_token")
    }
    guard id_token.split(".").collect() is [_, payload, _] else {
      raise InvalidIdToken("malformed JWT")
    }
    let decoded = @base64.decode(payload, url_safe=true) catch {
      _ => raise InvalidIdToken("payload is not base64url")
    }
    guard (@json.parse(
        @utf8.decode(decoded[:]) catch {
          _ => raise InvalidIdToken("payload is not UTF-8")
        },
      ) catch {
        _ => raise InvalidIdToken("payload is not JSON")
      })
      is Object(claims) else {
      raise InvalidIdToken("payload is not an object")
    }
    // JWT claims are unix seconds (RFC 7519) — protocol boundary.
    let now = (@env.now() / 1000).reinterpret_as_int64()
    guard claims.get("iss") is Some(String(iss)) && iss == self.issuer else {
      raise ClaimMismatch("iss")
    }
    let aud_ok = match claims.get("aud") {
      Some(String(a)) => a == self.client_id
      Some(Array(list)) =>
        list.iter().any(a => a is String(a) && a == self.client_id)
      _ => false
    }
    guard aud_ok else { raise ClaimMismatch("aud") }
    match claims.get("exp") {
      Some(Number(exp, ..)) if exp > now.to_double() => ()
      Some(Number(exp, ..)) => raise TokenExpired(exp.to_int64(), now)
      _ => raise InvalidIdToken("missing exp")
    }
    if nonce != "" {
      guard claims.get("nonce") is Some(String(n)) && n == nonce else {
        raise ClaimMismatch("nonce")
      }
    }
    claims
  } else {
    guard self.userinfo_url != "" else {
      raise InvalidTokenResponse("no id_token and no userinfo endpoint")
    }
    let (response, data) = @http.get(self.userinfo_url, headers={
      "Authorization": "Bearer \{tokens.access_token}",
      "Accept": "application/json",
    }) catch {
      e =>
        raise UserInfoFailed(0, "userinfo endpoint unreachable", cause=Some(e))
    }
    let text = data.text() catch {
      e => raise UserInfoFailed(response.code, "", cause=Some(e))
    }
    guard response.code == 200 else {
      raise UserInfoFailed(response.code, text, cause=None)
    }
    guard (@json.parse(text) catch {
        e => raise UserInfoFailed(0, text, cause=Some(e))
      })
      is Object(claims) else {
      raise UserInfoFailed(0, text, cause=None)
    }
    claims
  }
  // Map the verified claims onto an Identity. `sub` is required (OIDC);
  // plain-OAuth providers that only expose `id` get coerced into it.
  let sub = match claims.get("sub") {
    Some(String(sub)) => sub
    _ =>
      match claims.get("id") {
        Some(Number(id, ..)) => id.to_int64().to_string()
        Some(String(id)) => id
        _ => raise InvalidIdToken("missing sub")
      }
  }
  let email = match claims.get("email") {
    Some(String(email)) => Some(email)
    _ => None
  }
  // some providers serialize the flag as a string
  let email_verified = match claims.get("email_verified") {
    Some(True) | Some(String("true")) => true
    _ => false
  }
  let display_name = match claims.get("name") {
    Some(String(name)) => name
    _ =>
      match claims.get("preferred_username") {
        Some(String(name)) => name
        _ =>
          match claims.get("login") {
            Some(String(name)) => name
            _ => email.unwrap_or(sub)
          }
      }
  }
  Identity::{
    provider: self.name,
    sub,
    email,
    email_verified,
    display_name,
    tokens,
  }
}

///|
/// Generate a cryptographically random URL-safe token suitable for CSRF
/// `state`, PKCE `code_verifier`, or OIDC `nonce`.
pub fn generate_token() -> String raise OAuthError {
  guard @env.rand(32) is Some(bytes) else { raise EntropyUnavailable }
  b64url(bytes[:])
}

///|
/// The printable ASCII symbols that must be percent-escaped inside a
/// form/query value — everything outside RFC 3986's unreserved set
/// (`A-Z a-z 0-9 - . _ ~`, which always pass through).
let query_escapes : String = "!\"#$%&'()*+,/:;<=>?@[\\]^`{|} "

///|
/// base64url without padding — the encoding PKCE challenges, OIDC tokens
/// and JWT segments share (RFC 4648 Section 5).
fn b64url(bytes : BytesView) -> String {
  let s = @base64.encode(bytes, url_safe=true)
  let mut end = s.length()
  while end > 0 && s[end - 1] == '=' {
    end -= 1
  }
  s[:end].to_owned()
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
  /// seconds until `access_token` expiry; a JSON number on the wire
  expires_in : Double?
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
/// `cause` carries the underlying transport/parse error when one
/// exists (`None` for HTTP error responses, whose detail is the body).
///
/// The `Show` impl (what `Error::to_string` prints) omits response
/// bodies on purpose: `TokenExchangeFailed`/`UserInfoFailed`/
/// `InvalidTokenResponse` carry raw provider payloads that can embed
/// access/refresh tokens, so the printable form keeps only the
/// variant, upstream status, and transport `cause`. The full payload
/// stays accessible through pattern matching and `Debug`.
pub(all) suberror OAuthError {
  EntropyUnavailable
  TokenExchangeFailed(Int32, String, cause~ : Error?)
  InvalidTokenResponse(String)
  InvalidIdToken(String)
  ClaimMismatch(String)
  TokenExpired(Int64, Int64)
  UserInfoFailed(Int32, String, cause~ : Error?)
} derive(Debug)

///|
pub extend OAuthError with Debug::{to_repr}

///|
pub impl Show for OAuthError with fn to_string(self) {
  match self {
    EntropyUnavailable => "EntropyUnavailable"
    TokenExchangeFailed(code, _, cause~) =>
      match cause {
        Some(c) => "TokenExchangeFailed(\{code}, cause=\{c})"
        None => "TokenExchangeFailed(\{code})"
      }
    InvalidTokenResponse(_) => "InvalidTokenResponse(<body omitted>)"
    InvalidIdToken(msg) => "InvalidIdToken(\{msg})"
    ClaimMismatch(claim) => "ClaimMismatch(\{claim})"
    TokenExpired(exp, now) => "TokenExpired(\{exp}, \{now})"
    UserInfoFailed(code, _, cause~) =>
      match cause {
        Some(c) => "UserInfoFailed(\{code}, cause=\{c})"
        None => "UserInfoFailed(\{code})"
      }
  }
}

///|
pub extend OAuthError with Show::{to_string, output}
