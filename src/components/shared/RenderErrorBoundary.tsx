import { Component, type ReactNode } from "react";

export class RenderErrorBoundary extends Component<
  { children: ReactNode },
  { failed: boolean }
> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <div role="alert" className="mx-auto my-8 max-w-lg rounded-lg border border-border bg-card p-6 text-center text-foreground">
        <h1 className="font-display text-xl font-semibold">Não foi possível abrir esta tela</h1>
        <p className="mt-3 text-sm text-muted-foreground">
          Ocorreu um erro ou uma atualização ficou disponível. Recarregue para tentar novamente.
        </p>
        <button
          type="button"
          className="mt-5 inline-flex h-9 items-center justify-center rounded-md border border-border px-4 text-sm font-medium hover:bg-muted"
          onClick={() => window.location.reload()}
        >
          Recarregar página
        </button>
      </div>
    );
  }
}
