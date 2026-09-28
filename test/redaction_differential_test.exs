defmodule Imp.RedactionDifferentialTest do
  use ExUnit.Case, async: true

  # Checks Imp.Redaction against the rules it replaces (`MainRedaction`, a
  # frozen copy in test/support) and against this repository's own text. The
  # corpus is fake secrets in the places real ones turn up: env dumps, curl
  # traces, JSON, YAML, tracebacks, signed URLs, private keys. Vendor prefixes
  # are split with an empty interpolation so no line here reads as a live
  # token to a secret scanner.

  defp corpus do
    sk = "sk-FAKEopenai" <> String.duplicate("a1", 12)
    skp = "sk-proj-FAKEproj" <> String.duplicate("b2", 12)
    ska = "sk-ant-api03-FAKEant" <> String.duplicate("c3", 20)
    skor = "sk-or-v1-FAKEor" <> String.duplicate("d4", 24)
    ghp = "gh" <> "p_FAKEgh" <> String.duplicate("e5", 15)
    hf = "h" <> "f_FAKEhf" <> String.duplicate("f6", 15)
    akia = "AKIAFAKEAKIA1234567Z"
    aiza = "AIzaFAKEgoogle" <> String.duplicate("g", 25)
    jwt = "eyJFAKEjwthdr012345.eyJFAKEjwtpay012345.FAKEjwtsig0123"
    b64 = fn s -> Base.encode64(s) end
    basic_val = b64.("alice:FAKEbasicpw")
    b64basic = basic_val

    cases = [
      # Token shapes on their own, one per line, with nothing else to hide them.
      {"tokens alone", "#{skp}\n#{hf}\n#{aiza}\n#{jwt}\n#{b64basic}", []},
      # env dumps
      {"env: phoenix",
       """
       OPENAI_API_KEY=#{sk}
       SECRET_KEY_BASE=FAKEskb#{String.duplicate("Q", 40)}
       RELEASE_COOKIE=FAKEcookie123456
       PGPASSWORD=FAKEpgpass99
       MYSQL_PWD=FAKEmysqlpwd
       DB_PASS=FAKEdbpass
       SMTP_PASSWD=FAKEsmtppasswd
       API_KEY_OPENAI=FAKEapikeyopenai
       SLACK_WEBHOOK_URL=https://hooks#{"."}slack.com/services/T000/B000/FAKEslackhook123
       SENTRY_DSN=https://FAKEsentrypub@o1.ingest.sentry.io/1
       AZURE_STORAGE_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=acct;AccountKey#{"="}FAKEazacctkey+abc==;EndpointSuffix=core.windows.net
       PASSPHRASE=FAKEpassphrase
       ENCRYPTION_KEY=FAKEenckey
       """, []},
      {"env: stripe etc",
       """
       ANTHROPIC_API_KEY=#{ska}
       STRIPE_SECRET_KEY=sk#{"_"}live_FAKEstripe0123456789abcd
       STRIPE_RESTRICTED=rk#{"_"}live_FAKEstriperk0123456789
       STRIPE_WEBHOOK_SECRET=whsec#{"_"}FAKEwhsec012345
       TWILIO_AUTH_TOKEN=FAKEtwilio0123456789abcdef012345
       SENDGRID=SG#{"."}FAKEsendgrid0123.FAKEsendgrid4567890abcdef
       NPM_CONFIG=//registry.npmjs.org/:_authToken=npm#{"_"}FAKEnpm0123456789abcdefghijklmnop
       PYPI=pypi#{"-"}AgEIcHlwaS5vcmcFAKEpypi0123456789
       GOOGLE_OAUTH=ya29#{"."}FAKEya29token0123456789
       GITLAB=glpat#{"-"}FAKEgitlab012345678
       VAULT=hvs#{"."}FAKEvault0123456789abcdef
       OPENROUTER_API_KEY=#{skor}
       """, []},
      {"env: export lines",
       """
       export OPENAI_API_KEY="#{sk}"
       export DATABASE_URL="postgres://app:FAKEdbpw99@db:5432/app"
       export AZURE_OPENAI_KEY=FAKEazurekey0123456789abcdef0123
       export GH_PAT=#{ghp}
       export MY_TOKEN_VALUE=FAKEmytokval
       """, []},
      # netrc
      {"netrc + sk",
       "machine api.openai.com login x password #{sk}\nmachine github.com login alice password FAKEnetrcpw\n",
       []},
      {"netrc + bearer",
       "Authorization: Bearer abcdefghij0123456789\nmachine github.com\n  login alice\n  password FAKEnetrcpw2\n",
       []},
      # curl -v
      {"curl -v",
       """
       > POST /v1/chat HTTP/2
       > Host: api.openai.com
       > authorization: Bearer #{sk}
       > x-vault-token: FAKEvaulthdr123
       > Ocp-Apim-Subscription-Key: FAKEocpapim0123456789
       > X-Figma-Token: FAKEfigma012345
       > Cookie: sessionid=FAKEdjangosess; csrftoken=FAKEcsrf; _imp_key=FAKEphxcookie; JSESSIONID=FAKEjsess; connect.sid=s%3AFAKEconnect
       >
       < HTTP/2 200
       < set-cookie: __Secure-next-auth.session-token=FAKEnextauth; Path=/; HttpOnly
       < set-cookie: sid=FAKEsidcookie; Path=/
       < x-request-id: req_123
       """, []},
      {"auth casings",
       Enum.map_join(
         [
           "Authorization",
           "authorization",
           "AUTHORIZATION",
           "Proxy-Authorization",
           "X-Authorization"
         ],
         "\n",
         fn h -> "#{h}: Bearer FAKEbear#{h}xx" end
       ) <>
         "\nAuthorization: Token FAKEtokscheme\nAuthorization: token FAKEtoklower\nAuthorization: Digest username=\"a\", response=\"FAKEdigestresp\"\nAuthorization: AWS4-HMAC-SHA256 Credential=#{akia}/2026/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=FAKEsigv4sig0123\nAuthorization: FAKErawauthvalue\n",
       []},
      {"bearer mid-line + sk", "using Bearer FAKEbearermidline012 for #{sk} call", []},
      # JSON / inspect
      {"json nested",
       ~s({"config":{"api_key":"#{sk}","db":{"passwd":"FAKEjsonpasswd","pwd":"FAKEjsonpwd","pass":"FAKEjsonpass"},"webhook":"https://hooks#{"."}slack.com/services/T/B/FAKEjsonhook","headers":{"X-Vault-Token":"FAKEjsonvault","Cookie":"sessionid=FAKEjsoncookie"}}}),
       []},
      {"json escaped",
       ~s({"authorization":"Bearer #{sk}","password":"FAKEesc\\"aped\\"pw","note":"x"}), []},
      {"elixir inspect",
       inspect(%{
         api_key: sk,
         conn: %{pass: "FAKEexpass", opts: [password: "FAKEkwpw", passwd: "FAKEkwpasswd"]},
         cookie: "sessionid=FAKEexcookie"
       }), []},
      {"elixir inspect charlist",
       ~s(%{api_key: "#{sk}", password: ~c"FAKEcharlistpw", secret: 'FAKEsinglequote'}), []},
      # YAML/TOML/INI
      {"yaml",
       """
       openai:
         api_key: #{sk}
       database:
         password: FAKEcorrect FAKEhorse FAKEbattery
         passwd: FAKEyamlpasswd
       smtp:
         pass: FAKEyamlpass
       webhook: https://hooks#{"."}slack.com/services/T/B/FAKEyamlhook
       """, []},
      {"yaml multiline",
       "api_key: #{sk}\nprivate_key: |\n  FAKEyamlblockline1\n  FAKEyamlblockline2\npassword: >-\n  FAKEfolded\n",
       []},
      {"toml",
       ~s(api_key = "#{sk}"\n[db]\npassword = 'FAKEtomlpw'\npass = "FAKEtomlpass"\n[s3]\nsecret_access_key = """FAKEtomlmulti"""\n),
       []},
      {"ini",
       "[default]\naws_access_key_id = #{akia}\naws_secret_access_key = FAKEinisecret/abc+def\naws_session_token = FAKEinisess\n[db]\npass = FAKEinipass\nuser_pwd=FAKEinipwd\n",
       []},
      # Python tracebacks
      {"py traceback kwargs",
       """
       Traceback (most recent call last):
         File "app.py", line 3, in <module>
           client = OpenAI(api_key="#{sk}", organization="org-x")
         File "db.py", line 9, in connect
           psycopg2.connect(host="h", user="u", password="FAKEpytbpw", dbname="d")
         File "x.py", line 1, in f
           requests.get(url, auth=("alice", "FAKEpyauthtuple"), headers={"X-Vault-Token": "FAKEpyvault"})
         File "y.py", line 1, in g
           boto3.client("s3", aws_access_key_id="#{akia}", aws_secret_access_key="FAKEpyawssecret")
       openai.AuthenticationError: Incorrect API key provided: sk-FAKEtrunc***
       """, []},
      {"py locals repr",
       "locals: {'self': <C>, 'pw': 'FAKEpylocalpw', 'token': 'FAKEpylocaltok', 'key': '#{sk}'}",
       []},
      # presigned URLs
      {"s3 presigned",
       "https://b.s3.amazonaws.com/o?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=#{akia}%2F2026&X-Amz-Date=20260927T000000Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Security-Token=FAKEamzsts&X-Amz-Signature=FAKEamzsig0123",
       []},
      {"s3 v2 presigned",
       "https://b.s3.amazonaws.com/o?AWSAccessKeyId=#{akia}&Expires=1&Signature=FAKEv2sig%2Babc",
       []},
      {"gcs signed",
       "https://storage.googleapis.com/b/o?X-Goog-Algorithm=GOOG4-RSA-SHA256&X-Goog-Credential=svc%40p.iam.gserviceaccount.com&X-Goog-Signature=FAKEgoogsig0123 with #{sk}",
       []},
      {"gcs v2",
       "https://storage.googleapis.com/b/o?GoogleAccessId=svc@p.iam&Expires=1&Signature=FAKEgcsv2sig #{sk}",
       []},
      {"azure sas",
       "https://acct.blob.core.windows.net/c/b?sv=2022-11-02&ss=b&srt=o&sp=r&se=2026&st=2026&spr=https&sig=FAKEazsig%3D #{sk}",
       []},
      {"azure sas sig first", "https://acct.blob.core.windows.net/c/b?sig=FAKEazsig2&sv=1", []},
      # database URLs
      {"db urls",
       "postgres://u:FAKEpgurlpw@h/d mysql://root:FAKEmyurl@h redis://:FAKEredispw@h:6379 mongodb+srv://u:FAKEmongo@db.example.test/?retryWrites=true amqp://guest:FAKEamqp@h #{sk}",
       []},
      {"db url special chars", "DATABASE_URL=postgres://u:FAKEp@ss:w0rd@h/d and #{sk}", []},
      {"jdbc", "jdbc:postgresql://h:5432/d?user=u&password=FAKEjdbcpw&ssl=true #{sk}", []},
      {"odbc", "Server=tcp:h,1433;Database=d;User ID=u;Password=FAKEodbcpw;Encrypt=True; #{sk}",
       []},
      # vendor tokens
      {"vendor bare",
       "keys: sk#{"_"}live_FAKEstripebare0123456789 rk#{"_"}live_FAKErkbare0123456 SG#{"."}FAKEsgbare01234.FAKEsgbare2abcdef npm#{"_"}FAKEnpmbare0123456789abcdefghijklmn pypi#{"-"}AgEIcHlwaS5vcmcFAKEpypibare ya29#{"."}FAKEya29bare012345 xoxb#{"-"}FAKEslackbare0123 #{sk}",
       []},
      {"twilio",
       "client = Client('AC#{""}FAKEtwiliosid0123456789abcdef01', 'FAKEtwiliotoken0123456789abcdef') # #{sk}",
       []},
      {"azure key header", "api-key: FAKEazureapikey0123456789abcdef01\n#{sk}", []},
      # private keys
      {"openssh",
       "-----BEGIN OPENSSH PRIVATE KEY-----\nFAKEopensshbody\n-----END OPENSSH PRIVATE KEY-----",
       []},
      {"pgp",
       "-----BEGIN PGP PRIVATE KEY BLOCK-----\n\nFAKEpgpbody\n-----END PGP PRIVATE KEY BLOCK-----\n#{sk}",
       []},
      {"putty",
       "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: k\nPublic-Lines: 2\nAAAAC3NzaC1lZDI1NTE5AAAAIFAKEpub\nPrivate-Lines: 1\nAAAAIFAKEputtypriv\nPrivate-MAC: FAKEputtymac\n#{sk}",
       []},
      {"pem one-line escaped",
       ~s({"private_key": "-----BEGIN PRIVATE KEY-----\\nFAKEgcpkey\\n-----END PRIVATE KEY-----\\n", "client_email": "x"}),
       []},
      {"pem rsa encrypted",
       "-----BEGIN ENCRYPTED PRIVATE KEY-----\nFAKEencbody\n-----END ENCRYPTED PRIVATE KEY-----\nand DB_PASSWORD=FAKEafterpem",
       []},
      {"age", "AGE-SECRET#{"-"}KEY-1FAKEAGEKEY0123456789 #{sk}", []},
      # split across lines
      {"split token", "api_key=sk-FAKEsplit01234\n56789abcdef\nsecond part FAKEsplit2 #{sk}", []},
      {"bearer wrapped", "Authorization: Bearer\n  FAKEbearwrapped0123456789 #{sk}", []},
      # basic
      {"basic header", "Authorization: Basic #{b64basic}\nx-api-key: FAKExapikey", [b64basic]},
      {"basic mid-line", "curl -H 'Authorization: Basic #{b64basic}' https://x #{sk}",
       [b64basic]},
      {"basic in url", "https://alice:FAKEurlbasicpw@example.com/path #{sk}", []},
      {"basic -u", "curl -u alice:FAKEcurlupw https://x #{sk}", []},
      {"basic no-colon b64 trailing", "Basic #{b64basic} extra words", [b64basic]},
      # cookies
      {"cookie session",
       "Cookie: session=FAKEsesscookie012; theme=dark; remember_token=FAKEremember; _gh_sess=FAKEghsess\n#{sk}",
       []},
      {"set-cookie attrs",
       "Set-Cookie: auth_token=FAKEsetcookieauth; Secure; HttpOnly\nSet-Cookie: refresh=FAKEsetrefresh; Path=/",
       []},
      # markdown
      {"markdown code",
       "Run this:\n\n```bash\nexport OPENAI_API_KEY=#{sk}\ncurl -H \"Authorization: Bearer $OPENAI_API_KEY\" -d '{\"password\":\"FAKEmdpw\"}'\nmysql -u root -pFAKEmysqlflag\n```\n",
       []},
      {"markdown inline",
       "Set `API_KEY=FAKEmdinline` and `password: FAKEmdinline2`, then `#{sk}`", []},
      # value characters that end or reject a bare value
      {"bare value punct",
       "DB_PASSWORD=FAKEab(cd)ef\nAPI_TOKEN=FAKEp;art2\nCLIENT_SECRET=FAKEx,y\nSERVICE_TOKEN=:FAKEcolonstart\nACCESS_TOKEN=FAKE[bracket]\npassword=FAKEp<w>d\n#{sk}",
       []},
      {"value with spaces unquoted", "password = FAKEcorrect FAKEhorse\n#{sk}", []},
      {"quoted value containing token", ~s("password": "FAKEpre #{ghp} FAKEpost"), []},
      {"hex creds",
       "github_token=FAKE0123456789abcdef0123456789abcdef hmac_key=FAKEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa eos_token=FAKEbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
       []},
      {"session assign main", "session=FAKEsessmain0123 and x-other: FAKEotherhdr", []},
      {"mcp error",
       ~s|** (MatchError) no match of right hand side value: {:error, %{"message" => "Unauthorized", "headers" => [{"authorization", "Bearer #{sk}"}, {"x-vault-token", "FAKEmcpvault"}]}}|,
       []},
      {"elixir keyword tuple",
       ~s([{"authorization", "Bearer FAKEtupbearer0123456"}, {"x-goog-api-key", "FAKEtupgoog"}, {"x-vault-token", "FAKEtupvault"}]),
       []}
    ]

    hex = "0badcafe0badcafe0badcafe0badcafe"
    hex40 = hex <> "12345678"

    standalone = [
      "hf_token=#{hex}",
      "github_token=#{hex40}",
      "npm_token: #{hex}",
      "githubToken: #{hex}",
      "vault_token = \"#{hex}\"",
      "webhook_token=#{hex}",
      "csrf_token=#{hex}",
      "oauth_token=#{hex}",
      "mytokens=#{hex}",
      "slack_bot_token=#{hex}",
      "GitHubToken=#{hex}",
      "apikey=#{hex}",
      "hmac_secret=#{hex}",
      "credential=#{hex}",
      "passwords: #{hex}",
      "eos_token=#{hex}",
      "sort_key=#{hex}",
      "Session = FAKEsess12345",
      "SESSION=FAKEsess12345",
      "x session=FAKEsess12345;",
      "Authorization: Bearer FAKEtok1234567890 trailing",
      "bearer FAKEtok1234567890",
      "BeArEr FAKEtok1234567890",
      "Basic YWxpY2U6RkFLRXB3",
      "bAsIc YWxpY2U6RkFLRXB3",
      "AKIAFAKEFAKEFAKEFAKE",
      "prefix sk-FAKEaaaaaaaa suffix",
      "AIza" <> String.duplicate("F", 35),
      "Authorization: Bearer FAKEtok1234567890\r\n",
      "token:#{hex}",
      "Authorization:Bearer FAKEtok1234567890",
      "{\"Authorization\":\"Bearer FAKEtok1234567890\"}",
      "Bearer FAKEtok1234567890==",
      "Bearer FAKEtok1234567+/=\n",
      "Bearer\tFAKEtok1234567890",
      "'Bearer FAKEtok1234567890'",
      "(Bearer FAKEtok1234567890)",
      "[Bearer FAKEtok1234567890]",
      "Bearer FAKEtok1234567890.",
      "Bearer FAKEtok1234567890!"
    ]

    Enum.map(cases, fn {name, text, _extra} -> {name, text} end) ++
      Enum.map(standalone, &{&1, &1})
  end

  test "no input the previous rules redact comes back unredacted" do
    redacted_by_main =
      for {name, text} <- corpus(), MainRedaction.redact(text) != text, do: {name, text}

    assert length(redacted_by_main) > 50

    for {name, text} <- redacted_by_main do
      assert Imp.Redaction.redact(text) == "[REDACTED]", "#{name} came back unredacted"
    end
  end

  # The capture pipeline Imp.ExternalCommand had before this rule set: its own
  # `sk-` and `Bearer` replacements as output was captured, then the previous
  # whole-string rule over the result.
  defp main_capture(text) do
    text
    |> String.replace(~r/\bsk-[A-Za-z0-9_-]{8,}\b/, "[REDACTED]")
    |> String.replace(~r/\bBearer\s+[A-Za-z0-9._~+\/=\-]{12,}\b/i, "Bearer [REDACTED]")
    |> MainRedaction.redact()
  end

  defp command_outputs do
    sk = "sk-FAKEopenai" <> String.duplicate("a1", 12)

    [
      {"key after a hyphen", "flag x-#{sk} set\n"},
      {"printenv",
       "HOME=/root\nOPENAI_API_KEY=#{sk}\nSECRET_KEY_BASE=FAKEskbQQQQQQQQQQQQ\nPGPASSWORD=FAKEpgpass99\nRELEASE_COOKIE=FAKEcookie\nSTRIPE_KEY=FAKEstripeplain\n"},
      {"curl -v",
       "> GET / HTTP/2\n> authorization: Bearer #{sk}\n> x-api-key: FAKExapikey123\n> Cookie: sessionid=FAKEdjangosess\n< set-cookie: sid=FAKEsidcookie\n"},
      {"kubectl secret yaml",
       "apiVersion: v1\ndata:\n  password: RkFLRWs4c3B3\n  token: #{sk}\nkind: Secret\n"},
      {"docker inspect env",
       "\"Env\": [\n  \"OPENAI_API_KEY=#{sk}\",\n  \"DB_PASSWORD=FAKEdockerpw\"\n]"},
      {"git remote -v",
       "origin https://x-access-token:FAKEghinstall@github.com/o/r (fetch)\nbackup https://FAKEonlytoken@github.com/o/r (push)\n"},
      {"netrc cat",
       "machine api.openai.com login x password #{sk}\nmachine github.com login alice password FAKEnetrcpw\n"},
      {"json pretty", "{\n  \"api_key\": \"#{sk}\",\n  \"password\": \"FAKEjsonpw\"\n}"},
      {"pem then env",
       "-----BEGIN PRIVATE KEY-----\nFAKEpembody\n-----END PRIVATE KEY-----\nDB_PASSWORD=FAKEafterpem\n"},
      {"aws env",
       "AWS_ACCESS_KEY_ID=AKIAFAKEAKIA1234567Z\nAWS_SECRET_ACCESS_KEY=FAKEawssecret/abc+def\nAWS_SESSION_TOKEN=FAKEawssess\n"},
      {"aws credentials file",
       "access_key     ****************FAKE shared-credentials-file\n[default]\naws_access_key_id = AKIAFAKEAKIA1234567Z\naws_secret_access_key = FAKEinisecret\n"},
      {"hex token env",
       "GITHUB_TOKEN=0badcafe0badcafe0badcafe0badcafe12345678\nNPM_PASS=FAKEnpmpass\n"},
      {"cookie session vault",
       "Cookie: session=FAKEsesscookie012; csrftoken=FAKEcsrf\nX-Vault-Token: FAKEvault\n"},
      {"basic end", "Authorization: Basic YWxpY2U6RkFLRWJhc2ljcHc=\nx-api-key: FAKExapi2"},
      {"only a password", "DB_PASSWORD=FAKEalonepw\nready\n"},
      {"bearer then netrc",
       "Authorization: Bearer abcdefghij0123456789\nmachine github.com\n  login alice\n  password FAKEnetrcpw2\n"}
    ]
  end

  test "command output: nothing the previous capture pipeline hid is shown" do
    hidden_by_main =
      for {name, text} <- command_outputs() ++ corpus(), main_capture(text) != text do
        {name, text}
      end

    assert length(hidden_by_main) > 60

    for {name, text} <- hidden_by_main do
      assert {:ok, result} = Imp.ExternalCommand.run("printf", ["%s", text])
      assert result.output == "[REDACTED]", "#{name} showed what the previous pipeline hid"
    end
  end

  # Model answers, prompts and code that name credentials without holding
  # one. Neither rule set may change them.
  @ordinary [
    "question -> answer",
    "context: list[str], question: str -> answer: str",
    "reasoning: Let's think step by step. x = 3, y = x^2 = 9. answer: 9",
    ~s({"answer": "42", "confidence": 0.9}),
    ~s({"token": "hello", "logprob": -0.12}),
    ~s({"session": "morning keynote", "room": "A"}),
    ~s({"auth": "required", "status": 401}),
    ~s({"password": "must be 12+ chars"}),
    "The secret: always cache your regexes.",
    "Password: see the vault.",
    "Auth: OAuth2 via Google",
    "Token: 'the' has id 1996",
    "token = tokenizer.encode(text)[0]",
    "url = base + \"?token=\" + tok\nprint(url)\nmore code\n",
    "params = \"api_key=\" + key  # build query\nresult = fetch(params)\n",
    "session = requests.Session()\nr = session.get(u)\n",
    "E = mc^2; key=value pairs; sort_key=lambda x: x",
    "x = 5 and y: 10 => z",
    "Basic arithmetic: 2+2=4",
    "Bearer bonds are bearer instruments",
    "The bearer: a courier",
    "the api_key: must be set via env",
    "sk-learn is a library",
    "github_pat_ is a prefix",
    "https://example.com/search?key=value&q=elixir",
    "https://maps.example.com/?sig=abc",
    "ftp://user:pass@host",
    "see http://a:b@c",
    "time 12:34:56@UTC",
    "The DB_PASSWORD env var must be set.",
    "Authorization: required",
    "authorization: pending review by the board",
    "credential: a teaching credential from the state",
    "\"secret\": \"The treasure is under the oak\"",
    "tokens: 128, prompt_tokens: 50",
    "max_tokens: 256",
    "auth_token: nil",
    "access_token: String.t()",
    "password: String.t() | nil",
    "keyid=fingerprint-of-pgp-key",
    "\"token\" => \"<eos>\"",
    "signature: \"question -> answer\""
  ]

  test "answers, prompts and code that only name a credential are left alone" do
    for text <- @ordinary, text not in ["ftp://user:pass@host", "see http://a:b@c"] do
      assert Imp.Redaction.redact(text) == text
    end
  end

  # Prose, docs and code that put a word after `Bearer`. A token is found
  # when it ends the string or is closed by punctuation, or when it has a
  # digit and 16 or more characters; none of these is one.
  @bearer_prose [
    "Send it as a Bearer self-contained token in the Authorization header.",
    "Use Bearer token-based-auth here",
    "The Bearer JWT-formatted header",
    "a Bearer token/API-key pair",
    "BEARER THE-QUICK-BROWN fox",
    "| Authorization | Bearer YOUR_API_KEY |",
    "Bearer 2FA tokens are common",
    "Bearer token-based authentication is used",
    "Send a bearer self-contained token",
    "bearer short-lived tokens",
    ~s(`"Bearer " <> token`),
    ~s|put_req_header(conn, "authorization", "Bearer " <> token)|,
    "| Header | Value |\n|---|---|\n| Authorization | Bearer <token> |",
    "curl -H 'Authorization: Bearer $OPENAI_API_KEY' https://x",
    "Authorization: Bearer ${TOKEN}",
    "Authorization: Bearer YOUR_API_KEY here",
    "Bearer bonds are bearer instruments",
    "The bearer of bad news.\nNext line",
    "Clients authenticate with bearer credentials.\nThen",
    "OAuth 2.0 Bearer Token Usage (RFC 6750) defines it",
    "Bearer v1.2.3-beta release notes",
    "bearer 2024-01-01T00:00:00Z",
    "Bearer lookahead-and-lookbehind rules",
    "answer: Bearer instruments-of-debt are transferable",
    "The Bearer scheme (RFC-6750-section-2) says",
    "ex: Bearer abc.def.ghi more",
    "Bearer\tfoo-bar-baz-qux text",
    "reasoning: The bearer 12345678901 is a number",
    "bearer id=1234567890123 next"
  ]

  test "prose, docs and code with a word after Bearer are left alone" do
    for text <- @bearer_prose do
      assert Imp.Redaction.redact(text) == text
    end
  end

  test "a URL with a password in its user info is redacted, which the previous rules missed" do
    for text <- ["ftp://user:pass@host", "see http://a:b@c"] do
      assert MainRedaction.redact(text) == text
      assert Imp.Redaction.redact(text) == "[REDACTED]"
    end
  end

  # Lines of this repository that the rules change: every one must hold a
  # fake credential. A line the previous rules changed too is already
  # accounted for; a line only the current rules change must carry one of
  # the fake markers below.
  @fixture_markers ~w(CANARY canary FAKE F4ke EXAMPLE user:password@)

  test "in this repository's docs, livebooks, lib and tests, only fake credential lines change" do
    files =
      Path.wildcard("{docs,livebooks,lib,test}/**/*.{md,livemd,ex,exs}")
      |> Enum.reject(
        &(&1 in ["test/support/main_redaction.ex", "test/redaction_differential_test.exs"])
      )

    changed =
      for file <- files,
          {line, number} <- Enum.with_index(String.split(File.read!(file), "\n"), 1),
          Imp.Redaction.redact(line) != line,
          do: {file, number, line}

    assert changed != []

    unexplained =
      for {file, number, line} <- changed,
          MainRedaction.redact(line) == line,
          not String.contains?(line, @fixture_markers),
          do: "#{file}:#{number}: #{line}"

    assert unexplained == []
  end

  # Pairs written as two-element lists, as JSON writes config, headers and
  # tool results. Each case sits under a key that is not a credential name.
  @list_pair_value "FAKElistpairvalue"
  @list_pairs [
    {"mixed with a string", [["api_key", @list_pair_value], "note"]},
    {"mixed with a 3-list", [["api_key", @list_pair_value], ["a", "b", "c"]]},
    {"one pair", [["api_key", @list_pair_value]]},
    {"number first beside a pair", [[1, @list_pair_value], ["api_key", @list_pair_value]]},
    {"keyword list", [api_key: @list_pair_value, model: "gpt"]},
    {"tuples and 2-lists", [{"model", "gpt"}, ["api_key", @list_pair_value]]},
    {"pair beside nil", [["api_key", @list_pair_value], nil]},
    {"flat 2-list", ["api_key", @list_pair_value]},
    {"map key beside a pair", [[%{"k" => 1}, @list_pair_value], ["api_key", @list_pair_value]]},
    {"ragged headers", %{"headers" => [["x", "y"], ["api_key", @list_pair_value], ["z"]]}}
  ]

  defp hides_pair_value?(term),
    do: :binary.match(:erlang.term_to_binary(term), @list_pair_value) == :nomatch

  test "a pair written as a two-element list is redacted wherever the previous rules redacted it" do
    for {name, value} <- @list_pairs do
      input = %{value: value}

      if hides_pair_value?(MainRedaction.redact(input)) and name != "flat 2-list" do
        for {writer, redact} <- [
              redact: &Imp.Redaction.redact/1,
              redact_term: &Imp.Redaction.redact_term/1,
              drop_credentials: &Imp.Redaction.drop_credentials/1
            ] do
          assert hides_pair_value?(redact.(input)), "#{name} came back through #{writer}"
        end
      end
    end
  end

  # The one recorded divergence: a two-element list held directly as a value
  # is data, since it has the shape of a list of two names (an example's input
  # keys, a schema's required fields). The previous rules read it as a pair.
  test "a flat two-element list held as a value is data, where the previous rules redacted it" do
    input = %{value: ["api_key", @list_pair_value]}

    assert MainRedaction.redact(input) == %{value: ["api_key", "[REDACTED]"]}
    assert Imp.Redaction.redact(input) == input
    assert Imp.Redaction.redact_term(input) == input
  end

  # A table of rows whose first column holds credential names reads as pairs,
  # as it did before: the value beside `token` and `session` is redacted.
  test "a demo answer that is a table of rows is redacted as the previous rules did" do
    table = [["token", "the"], ["session", "keynote"]]
    demo = Imp.example(text: "the keynote", answer: table)
    program = %{Imp.Predict.new(Imp.Signature.new("text -> answer")) | demos: [demo]}

    loaded =
      program |> Imp.Saving.dump() |> Jason.encode!() |> Jason.decode!() |> Imp.Saving.load!()

    redacted = [["token", "[REDACTED]"], ["session", "[REDACTED]"]]
    assert MainRedaction.redact(%{answer: table}) == %{answer: redacted}
    assert Imp.Example.get(hd(loaded.demos), :answer) == redacted
  end

  test "a saved program's instructions and demos survive dump and load unchanged" do
    signature =
      Imp.Signature.new(
        "text -> token_label",
        "For each word, emit token: the word itself and session: the talk it came from. Auth: none required."
      )

    demos = [
      Imp.example(text: "the talk", token_label: ~s({"token": "the", "session": "keynote"})),
      Imp.example(
        text: "how do I send the key?",
        token_label: "Send it as a Bearer self-contained token in the Authorization header."
      )
    ]

    program = %{Imp.Predict.new(signature) | demos: demos}

    loaded = program |> Imp.Saving.dump() |> Imp.Saving.load!()

    assert loaded.signature.instructions == signature.instructions
    assert loaded.demos == demos
  end
end
