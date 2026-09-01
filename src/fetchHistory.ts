import { config } from "./config";
import { createClient, resolveChatId, normalizeChatId } from "./listener";
import { MessageStore } from "./messageStore";
import path from "path";

// One-off script for research: dumps the target group's message history
// covering the last HISTORY_DAYS days to a temp file, paging backwards
// since Telegram's API caps each getMessages call at 100 messages.
const HISTORY_DAYS = 30;
const PAGE_SIZE = 100;

async function main(): Promise<void> {
  const outputPath = path.join(path.dirname(config.dataFilePath), "history-fxd-vip.jsonl");
  const store = new MessageStore(outputPath);

  const client = await createClient();

  console.log(`Resolving target group "${config.targetGroupName}"...`);
  const targetChatId = await resolveChatId(client, config.targetGroupName);

  const cutoff = Date.now() - HISTORY_DAYS * 24 * 60 * 60 * 1000;
  console.log(
    `Fetching messages from chat ID: ${targetChatId} back to ${new Date(cutoff).toISOString()}`
  );

  let saved = 0;
  let offsetId = 0;
  let done = false;

  while (!done) {
    const messages = await client.getMessages(targetChatId, {
      limit: PAGE_SIZE,
      offsetId: offsetId || undefined
    });

    if (messages.length === 0) {
      break;
    }

    for (const message of messages) {
      const messageTimeMs = (message.date ?? 0) * 1000;
      if (messageTimeMs < cutoff) {
        done = true;
        break;
      }

      const chatId = normalizeChatId(message.chatId) ?? targetChatId;
      const text = message.message;
      if (!text || typeof text !== "string") {
        continue;
      }

      await store.append({
        chatId,
        chatTitle: config.targetGroupName,
        messageId: message.id,
        text,
        receivedAt: new Date(messageTimeMs).toISOString()
      });
      saved++;
    }

    offsetId = messages[messages.length - 1].id;
    console.log(`...fetched ${messages.length} more (offsetId=${offsetId}), saved ${saved} so far`);

    if (messages.length < PAGE_SIZE) {
      break;
    }
  }

  console.log(`Saved ${saved} messages to ${outputPath}`);
  await client.disconnect();
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
