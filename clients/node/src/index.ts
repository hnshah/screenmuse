export interface RecordingStatus {
  recording: boolean;
  elapsed: number;
  session_id: string;
  chapters: Array<{ name: string; time: number }>;
}

export interface RecordingResult {
  video_path: string;
  metadata: {
    session_id: string;
    name: string;
    elapsed: number;
    chapters: Array<{ name: string; time: number }>;
  };
}

export class ScreenMuse {
  private baseUrl: string;

  constructor(host = "localhost", port = 7823) {
    this.baseUrl = `http://${host}:${port}`;
  }

  async start(name: string): Promise<{ session_id: string; status: string; name: string }> {
    const r = await fetch(`${this.baseUrl}/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    });
    return r.json();
  }

  async stop(): Promise<RecordingResult> {
    const r = await fetch(`${this.baseUrl}/stop`, { method: "POST" });
    return r.json();
  }

  async markChapter(name: string): Promise<void> {
    await fetch(`${this.baseUrl}/chapter`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    });
  }

  async highlightNextClick(): Promise<void> {
    await fetch(`${this.baseUrl}/highlight`, { method: "POST" });
  }

  async status(): Promise<RecordingStatus> {
    const r = await fetch(`${this.baseUrl}/status`);
    return r.json();
  }
}

export default ScreenMuse;
