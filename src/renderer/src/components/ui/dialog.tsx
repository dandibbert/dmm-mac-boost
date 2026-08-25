import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

type Props = {
  open: boolean;
  title: string;
  description?: string;
  children: ReactNode;
  onClose: () => void;
  className?: string;
};

export function Dialog({ open, title, description, children, onClose, className }: Props) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center p-3 sm:items-center">
      <button
        type="button"
        className="absolute inset-0 bg-black/55"
        aria-label="关闭对话框"
        onClick={onClose}
      />
      <div
        className={cn(
          "relative w-full max-w-lg rounded-3xl border border-line bg-panel p-5 shadow-2xl sm:p-6",
          className
        )}
      >
        <h2 className="font-sans text-2xl text-paper">{title}</h2>
        {description ? <p className="mt-2 text-sm leading-6 text-mute">{description}</p> : null}
        <div className="mt-5">{children}</div>
      </div>
    </div>
  );
}
