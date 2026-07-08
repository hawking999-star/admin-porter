import pkg from "../../package.json";

/** Versão do app — fonte única: campo "version" do package.json. */
export const APP_VERSION: string = pkg.version;

/** Rótulo do ambiente exibido na sidebar. */
export const APP_ENVIRONMENT = "Produção";
