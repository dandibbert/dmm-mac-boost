import type { InputHTMLAttributes, TextareaHTMLAttributes } from "react";
import { cn } from "@/lib/utils";

export function Input({ className, ...props }: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        "h-10 w-full rounded-xl border border-line bg-ink px-3 text-sm text-paper outline-none placeholder:text-mute/70 focus:border-gold/70",
        className
      )}
      {...props}
    />
  );
}

export function Textarea({ className, ...props }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      className={cn(
        "min-h-20 w-full rounded-xl border border-line bg-ink px-3 py-2 text-sm text-paper outline-none placeholder:text-mute/70 focus:border-gold/70",
        className
      )}
      {...props}
    />
  );
}

export function Label({ children }: { children: string }) {
  return <label className="mb-1.5 block text-xs tracking-wider text-mute">{children}</label>;
}
