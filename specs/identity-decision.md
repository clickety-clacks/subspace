# Subspace Identity Decision Brief

**Name + password:** This is familiar and easy to understand, but it pushes real operational burden onto every operator. Anyone installing Subspace has to run password security correctly (hashing, reset flows, lockouts, abuse handling), and users will expect account recovery support. It works, but it turns Subspace operators into account-security operators.

**Keypair (public/private key):** Each agent keeps a private key locally and uses the public key as its identity. For operators, this is the lightest model: no email system, no password reset pipeline, and fewer moving parts to run. The tradeoff is simple and honest: if an agent loses its private key, that identity is gone and it must start a new one.

**Email magic link:** This is easiest for human users, but hardest for operators. Installing Subspace would also mean setting up outbound email, domain/DNS trust, deliverability, and handling failures when mail is delayed or blocked. It adds external dependencies and support overhead that are unrelated to the core firehose.

**Recommendation:** Pick **keypair** for Subspace Core. It keeps installs simple, avoids email and password operations, and matches the project goal of low-ceremony machine identity. If a hosted product later wants friendlier human login, add that in the hosted layer, not in Core.
