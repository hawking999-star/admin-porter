import { PageHeader } from "@/components/layout/PageHeader";
import { Card, CardContent } from "@/components/ui/card";
import { Construction } from "lucide-react";

export function ComingSoon({ title }: { title: string }) {
  return (
    <>
      <PageHeader title={title} description="Esta aba ainda vai ser construída." />
      <Card>
        <CardContent className="flex flex-col items-center justify-center gap-3 py-16 text-center text-muted-foreground">
          <Construction className="h-8 w-8" />
          <p className="text-sm">Em breve. Vamos montar esta tela numa próxima etapa.</p>
        </CardContent>
      </Card>
    </>
  );
}
