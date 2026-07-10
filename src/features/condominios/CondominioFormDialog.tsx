import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { createUnit, updateUnit, type Unit, type UnitInput } from "./queries";

const DEFAULT_TZ = "America/Sao_Paulo";

const BRAZILIAN_STATES = [
  { uf: "AC", name: "Acre" }, { uf: "AL", name: "Alagoas" }, { uf: "AP", name: "Amapá" },
  { uf: "AM", name: "Amazonas" }, { uf: "BA", name: "Bahia" }, { uf: "CE", name: "Ceará" },
  { uf: "DF", name: "Distrito Federal" }, { uf: "ES", name: "Espírito Santo" }, { uf: "GO", name: "Goiás" },
  { uf: "MA", name: "Maranhão" }, { uf: "MT", name: "Mato Grosso" }, { uf: "MS", name: "Mato Grosso do Sul" },
  { uf: "MG", name: "Minas Gerais" }, { uf: "PA", name: "Pará" }, { uf: "PB", name: "Paraíba" },
  { uf: "PR", name: "Paraná" }, { uf: "PE", name: "Pernambuco" }, { uf: "PI", name: "Piauí" },
  { uf: "RJ", name: "Rio de Janeiro" }, { uf: "RN", name: "Rio Grande do Norte" }, { uf: "RS", name: "Rio Grande do Sul" },
  { uf: "RO", name: "Rondônia" }, { uf: "RR", name: "Roraima" }, { uf: "SC", name: "Santa Catarina" },
  { uf: "SP", name: "São Paulo" }, { uf: "SE", name: "Sergipe" }, { uf: "TO", name: "Tocantins" },
] as const;

type IbgeCity = { nome: string };

async function listCitiesByState(state: string): Promise<string[]> {
  const response = await fetch(`https://servicodados.ibge.gov.br/api/v1/localidades/estados/${state}/municipios`);
  if (!response.ok) throw new Error("Não foi possível carregar as cidades deste estado.");
  const cities = (await response.json()) as IbgeCity[];
  return cities.map((city) => city.nome).sort((a, b) => a.localeCompare(b, "pt-BR"));
}

// O Brasil não usa mais horário de verão, então na prática só existem 4 horários.
// Um representante para cada, com os estados que caem em cada um.
const TIMEZONES: { value: string; label: string }[] = [
  { value: "America/Sao_Paulo", label: "Horário de Brasília (GMT-3) — maior parte do Brasil" },
  { value: "America/Manaus", label: "Amazônia (GMT-4) — AM, MT, MS, RO, RR" },
  { value: "America/Rio_Branco", label: "Acre (GMT-5) — AC e oeste do AM" },
  { value: "America/Noronha", label: "Fernando de Noronha (GMT-2)" },
];

// Converte qualquer fuso do Brasil (dados antigos) para um dos 4 acima,
// já que todos têm o mesmo horário na prática.
const TZ_CANONICAL: Record<string, string> = {
  "America/Sao_Paulo": "America/Sao_Paulo",
  "America/Bahia": "America/Sao_Paulo",
  "America/Fortaleza": "America/Sao_Paulo",
  "America/Recife": "America/Sao_Paulo",
  "America/Maceio": "America/Sao_Paulo",
  "America/Belem": "America/Sao_Paulo",
  "America/Santarem": "America/Sao_Paulo",
  "America/Araguaina": "America/Sao_Paulo",
  "America/Campo_Grande": "America/Manaus",
  "America/Cuiaba": "America/Manaus",
  "America/Manaus": "America/Manaus",
  "America/Porto_Velho": "America/Manaus",
  "America/Boa_Vista": "America/Manaus",
  "America/Rio_Branco": "America/Rio_Branco",
  "America/Eirunepe": "America/Rio_Branco",
  "America/Noronha": "America/Noronha",
};

function canonicalTz(tz: string | null | undefined): string {
  if (!tz) return DEFAULT_TZ;
  return TZ_CANONICAL[tz] ?? DEFAULT_TZ;
}

export function CondominioFormDialog({
  open,
  onOpenChange,
  unit,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  unit: Unit | null;
}) {
  const qc = useQueryClient();
  const isEdit = Boolean(unit);

  const [name, setName] = useState("");
  const [code, setCode] = useState("");
  const [address, setAddress] = useState("");
  const [city, setCity] = useState("");
  const [state, setState] = useState("");
  const [timezone, setTimezone] = useState(DEFAULT_TZ);
  const [active, setActive] = useState(true);
  const citiesQuery = useQuery({
    queryKey: ["ibge-cities", state],
    queryFn: () => listCitiesByState(state),
    enabled: open && Boolean(state),
    staleTime: Infinity,
    gcTime: 1000 * 60 * 60 * 24,
  });
  const cities = citiesQuery.data ?? [];
  const cityOptions = city && !cities.includes(city) ? [city, ...cities] : cities;

  useEffect(() => {
    if (open) {
      setName(unit?.name ?? "");
      setCode(unit?.code ?? "");
      setAddress(unit?.address ?? "");
      setCity(unit?.city ?? "");
      setState(unit?.state ?? "");
      setTimezone(canonicalTz(unit?.timezone));
      setActive(unit?.active ?? true);
    }
  }, [open, unit]);

  const mutation = useMutation({
    mutationFn: async (input: UnitInput) => {
      if (unit) await updateUnit(unit.id, input);
      else await createUnit(input);
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["units"] });
      toast.success(isEdit ? "Condomínio atualizado" : "Condomínio criado");
      onOpenChange(false);
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Erro ao salvar";
      toast.error("Não foi possível salvar", { description: msg });
    },
  });

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const clean = (v: string) => {
      const t = v.trim();
      return t.length ? t : null;
    };
    mutation.mutate({
      name: name.trim(),
      code: code.trim(),
      address: clean(address),
      city: clean(city),
      state: clean(state),
      timezone: timezone.trim() || DEFAULT_TZ,
      active,
    });
  };

  const onStateChange = (nextState: string) => {
    setState(nextState);
    setCity("");
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <form onSubmit={onSubmit}>
          <DialogHeader>
            <DialogTitle>{isEdit ? "Editar condomínio" : "Novo condomínio"}</DialogTitle>
            <DialogDescription>
              Uma unidade é um condomínio onde os operadores trabalham.
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="name">Nome</Label>
              <Input
                id="name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Ex.: Edifício Aurora"
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="code">Código</Label>
              <Input
                id="code"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="Ex.: AURORA-01"
                required
              />
              <p className="text-xs text-muted-foreground">
                Identificador único da unidade. Não pode repetir.
              </p>
            </div>
            <div className="space-y-2">
              <Label htmlFor="address">Endereço</Label>
              <Input
                id="address"
                value={address}
                onChange={(e) => setAddress(e.target.value)}
                placeholder="Ex.: Av. Paulista, 1000"
              />
            </div>
            <div className="grid grid-cols-3 gap-3">
              <div className="col-span-2 space-y-2">
                <Label htmlFor="city">Cidade</Label>
                <Select value={city} onValueChange={setCity} disabled={!state || citiesQuery.isLoading || citiesQuery.isError}>
                  <SelectTrigger id="city">
                    <SelectValue
                      placeholder={!state ? "Selecione a UF primeiro" : citiesQuery.isLoading ? "Carregando cidades..." : "Selecione a cidade"}
                    />
                  </SelectTrigger>
                  <SelectContent>
                    {cityOptions.map((option) => (
                      <SelectItem key={option} value={option}>
                        {option}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {citiesQuery.isError && (
                  <p className="text-xs text-destructive">Não foi possível carregar as cidades. Tente selecionar a UF novamente.</p>
                )}
              </div>
              <div className="space-y-2">
                <Label htmlFor="state">UF</Label>
                <Select value={state} onValueChange={onStateChange}>
                  <SelectTrigger id="state">
                    <SelectValue placeholder="UF" />
                  </SelectTrigger>
                  <SelectContent>
                    {BRAZILIAN_STATES.map((option) => (
                      <SelectItem key={option.uf} value={option.uf}>
                        {option.uf} — {option.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>
            <div className="space-y-2">
              <Label>Fuso horário</Label>
              <Select value={timezone} onValueChange={setTimezone}>
                <SelectTrigger>
                  <SelectValue placeholder="Escolha o fuso" />
                </SelectTrigger>
                <SelectContent>
                  {TIMEZONES.map((tz) => (
                    <SelectItem key={tz.value} value={tz.value}>
                      {tz.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <p className="text-xs text-muted-foreground">
                Usado para os horários de plantão do condomínio.
              </p>
            </div>
            <div className="flex items-center justify-between rounded-md border border-border px-3 py-2">
              <div>
                <Label htmlFor="active">Ativo</Label>
                <p className="text-xs text-muted-foreground">Unidades inativas não recebem operação.</p>
              </div>
              <Switch id="active" checked={active} onCheckedChange={setActive} />
            </div>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancelar
            </Button>
            <Button type="submit" disabled={mutation.isPending}>
              {mutation.isPending ? "Salvando..." : "Salvar"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
