# PerlTea

A **terminal UI** framework in the Elm architecture.

## Features

- model / update / view
- a diffing renderer
- `tea.NewProgram(m)`

```go
func main() {
    tea.NewProgram(model{}).Run()
}
```

That is *all* you need to start.
