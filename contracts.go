// Package contracts is the shared contracts of Contelys as a Go module (ADR 0060). It holds no
// code beyond the embedded files: each deployable generates its own code from them.
package contracts

import "embed"

// OpenAPI holds every OpenAPI file of the contracts at its path in the repository, such as
// openapi/identity/openapi.yaml and openapi/shared/problem.yaml, so that a deployable's
// interface layer can validate requests against the contract it embeds.
//
//go:embed openapi/*/*.yaml
var OpenAPI embed.FS
