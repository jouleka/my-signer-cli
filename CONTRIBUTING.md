# Contributing

Thanks for helping improve My Signer CLI.

1. Open an issue before starting a large change.
2. Fork the repository and create a focused branch from `main`.
3. Use synthetic fixtures only; never add real signing material, API tokens, customer data, or production endpoints.
4. Run the checks below before opening a pull request.

```bash
bundle install
bundle exec rspec
bundle exec rubocop
bundle exec bundle-audit check --update
```

Pull requests should explain the behavior change and include tests. By submitting a contribution, you agree that it is licensed under Apache-2.0.
