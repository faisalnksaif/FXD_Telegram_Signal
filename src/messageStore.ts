import { appendFile, mkdir } from "fs/promises";
import path from "path";

export interface CapturedMessage {
  chatId: number;
  chatTitle?: string;
  messageId: number;
  text: string;
  receivedAt: string;
}

export class MessageStore {
  private readonly filePath: string;

  constructor(filePath: string) {
    this.filePath = filePath;
  }

  async append(message: CapturedMessage): Promise<void> {
    await mkdir(path.dirname(this.filePath), { recursive: true });
    await appendFile(this.filePath, `${JSON.stringify(message)}\n`, "utf-8");
  }
}
