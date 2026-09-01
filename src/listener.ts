import { mkdir, readFile, writeFile } from "fs/promises";
import path from "path";
import readline from "readline/promises";
import { TelegramClient } from "telegram";
import { NewMessage } from "telegram/events";
import { ConnectionTCPFull } from "telegram/network";
import { StringSession } from "telegram/sessions";
import { config } from "./config";
import { MessageStore } from "./messageStore";
import { SignalStore } from "./signalStore";
import { parseSignalMessage } from "./signalParser";
import { createApiServer } from "./apiServer";

export function normalizeChatId(chatId: unknown): number | null {
  if (typeof chatId === "number") {
    return Number.isFinite(chatId) ? chatId : null;
  }

  if (typeof chatId === "bigint") {
    const asNumber = Number(chatId);
    return Number.isFinite(asNumber) ? asNumber : null;
  }

  if (
    chatId &&
    typeof chatId === "object" &&
    "toString" in chatId &&
    typeof (chatId as { toString: () => string }).toString === "function"
  ) {
    const parsed = Number((chatId as { toString: () => string }).toString());
    return Number.isFinite(parsed) ? parsed : null;
  }

  return null;
}

export async function promptValue(promptText: string): Promise<string> {
  console.log(`Awaiting input: ${promptText}`);
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });

  try {
    const value = await rl.question(promptText);
    return value.trim();
  } finally {
    rl.close();
  }
}

export async function loadSessionString(params: {
  fromEnv?: string;
  sessionFilePath: string;
}): Promise<string> {
  const { fromEnv, sessionFilePath } = params;
  if (fromEnv && fromEnv.trim()) {
    return fromEnv.trim();
  }

  try {
    const content = await readFile(sessionFilePath, "utf-8");
    return content.trim();
  } catch {
    return "";
  }
}

export async function saveSessionString(sessionFilePath: string, value: string): Promise<void> {
  await mkdir(path.dirname(sessionFilePath), { recursive: true });
  await writeFile(sessionFilePath, value, "utf-8");
}

export async function resolveChatId(client: TelegramClient, groupNameOrId: string): Promise<number> {
  const asNumber = parseInt(groupNameOrId, 10);
  if (!isNaN(asNumber) && Number.isFinite(asNumber) && String(asNumber) === groupNameOrId.trim()) {
    return asNumber;
  }

  try {
    const username = groupNameOrId.startsWith("@") ? groupNameOrId : `@${groupNameOrId}`;
    const entity = await client.getEntity(username);

    if (entity && "id" in entity) {
      const chatId = typeof entity.id === "bigint" ? Number(entity.id) : (entity.id as unknown as number);
      console.log(`Resolved "${groupNameOrId}" to chat ID: ${chatId}`);
      return chatId;
    }
  } catch {
    // Username lookup failed, fall back to searching dialogs by title.
  }

  const dialogs = await client.getDialogs({ limit: 200 });
  for (const dialog of dialogs) {
    const entity = dialog.entity;
    if (!entity) {
      continue;
    }

    const title =
      ("title" in entity ? (entity as any).title : null) ||
      ("username" in entity ? (entity as any).username : null);

    if (title && title.toLowerCase() === groupNameOrId.toLowerCase()) {
      const chatId = typeof entity.id === "bigint" ? Number(entity.id) : (entity.id as unknown as number);
      console.log(`Resolved "${groupNameOrId}" to chat ID: ${chatId}`);
      return chatId;
    }
  }

  throw new Error(`Could not resolve group "${groupNameOrId}" to a chat ID`);
}

export async function createClient(): Promise<TelegramClient> {
  const savedSession = await loadSessionString({
    fromEnv: config.telegramStringSession,
    sessionFilePath: config.telegramSessionFilePath
  });

  const client = new TelegramClient(
    new StringSession(savedSession),
    config.telegramApiId,
    config.telegramApiHash as string,
    {
      connection: ConnectionTCPFull,
      useWSS: false,
      connectionRetries: 3,
      retryDelay: 1500
    }
  );

  console.log("Telegram client transport: TCPFull (WSS disabled)");
  await client.start({
    phoneNumber: async () => {
      if (config.telegramPhoneNumber) {
        console.log("Using TELEGRAM_PHONE_NUMBER from environment");
        return config.telegramPhoneNumber;
      }
      return promptValue("Telegram phone number:");
    },
    password: async () => {
      if (config.telegramPassword) {
        console.log("Using TELEGRAM_PASSWORD from environment");
        return config.telegramPassword;
      }
      return promptValue("Telegram 2FA password (if enabled):");
    },
    phoneCode: async () => {
      const envCode = config.telegramLoginCode?.trim();
      if (envCode) {
        console.log("Using TELEGRAM_LOGIN_CODE from environment");
        return envCode;
      }
      return promptValue("Telegram login code:");
    },
    onError: async (error) => {
      console.error("Telegram auth error:", error);
      return true;
    }
  });

  const rawSession = client.session.save();
  const newSession = typeof rawSession === "string" ? rawSession : "";
  if (newSession) {
    await saveSessionString(config.telegramSessionFilePath, newSession);
  }

  return client;
}

async function main(): Promise<void> {
  const store = new MessageStore(config.dataFilePath);
  const signalStore = new SignalStore();
  createApiServer(signalStore, config.apiPort);
  const client = await createClient();

  console.log(`Resolving target group "${config.targetGroupName}"...`);
  const targetChatId = await resolveChatId(client, config.targetGroupName);
  console.log(`Listening to chat ID: ${targetChatId}`);

  client.addEventHandler(async (event) => {
    const message = event.message;
    if (!message) {
      return;
    }

    const chatId = normalizeChatId(message.chatId);
    if (chatId === null || chatId !== targetChatId) {
      return;
    }

    const text = message.message;
    if (!text || typeof text !== "string") {
      return;
    }

    const receivedAt = new Date().toISOString();
    await store.append({
      chatId,
      chatTitle: config.targetGroupName,
      messageId: message.id,
      text,
      receivedAt
    });

    console.log(`[${receivedAt}] Captured message ${message.id}: ${text.slice(0, 80)}`);

    const signalEvent = parseSignalMessage(text);
    if (signalEvent) {
      const stored = signalStore.add(signalEvent, receivedAt);
      console.log(`[${receivedAt}] Stored signal event #${stored.seq}: ${signalEvent.type} ${signalEvent.symbol}`);
    }
  }, new NewMessage({}));

  console.log("Listener started. Session persisted in", config.telegramSessionFilePath);
}

const isMainModule = process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (isMainModule) {
  main().catch((error) => {
    console.error("Fatal error:", error);
    process.exit(1);
  });
}
