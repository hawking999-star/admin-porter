import { Sparkles, type LucideIcon } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Card } from "@/components/ui/card";
import { StatusBadge } from "./StatusBadge";

/**
 * Página "Em breve" padrão do Admin PTM.
 * Informativa apenas — não cria funcionalidade nem dados falsos.
 * Mostra o que a área fará quando existir, com o mesmo padrão visual do admin.
 */
export function ComingSoonPage({
  title,
  description,
  icon: Icon = Sparkles,
  planned,
}: {
  title: string;
  description: string;
  icon?: LucideIcon;
  /** Lista curta (3–5) do que está planejado para a área. Sem prometer demais. */
  planned: string[];
}) {
  return (
    <>
      <PageHeader
        title={title}
        description={description}
        action={<StatusBadge status="em_breve" dot={false} />}
      />

      <Card className="overflow-hidden shadow-sm">
        <div className="flex flex-col gap-6 p-6 md:flex-row md:items-start">
          <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary ring-1 ring-primary/20">
            <Icon className="h-7 w-7" />
          </div>
          <div className="min-w-0 flex-1">
            <h2 className="font-display text-lg font-semibold text-foreground">
              Planejado para esta área
            </h2>
            <p className="mt-1 text-sm text-muted-foreground">
              Esta tela ainda está em construção. Quando ficar pronta, você poderá acompanhar:
            </p>
            <ul className="mt-4 grid gap-2 sm:grid-cols-2">
              {planned.map((item) => (
                <li
                  key={item}
                  className="flex items-start gap-2.5 rounded-lg border border-border bg-muted/30 px-3 py-2.5 text-sm text-foreground"
                >
                  <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-primary" />
                  {item}
                </li>
              ))}
            </ul>
          </div>
        </div>
      </Card>
    </>
  );
}
