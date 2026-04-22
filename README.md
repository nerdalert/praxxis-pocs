# Praxis POCs

Proof-of-concept demos for [Praxis](https://github.com/praxis-proxy/praxis), an AI-native proxy built on Pingora.

These demos show Praxis replacing components in a MaaS (Models-as-a-Service) gateway stack — body-aware model routing, provider egress, and request classification without ext-proc or Wasm sidecars.

## Demos

See [demos/](demos/) for deployment instructions, architecture diagrams, and curl examples.

## Scripts

- [`scripts/validate-all.sh`](scripts/validate-all.sh) — full integration test suite covering Praxis BBR replacement, Praxis provider gateway, and existing MaaS gpt-4o routes

## License

MIT
