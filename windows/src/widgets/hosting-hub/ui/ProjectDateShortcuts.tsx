import { localScheduleToday, scheduleAddDays } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
/** Quick choices use calendar days; the caller persists the chosen date. */
export function ProjectDateShortcuts({
  choose,
  locked,
}: {
  choose: (value: string) => void;
  locked: boolean;
}) {
  const today = localScheduleToday();
  return (
    <div className="project-date-shortcuts">
      {[
        ["Today", 0],
        ["Tomorrow", 1],
        ["In 1 week", 7],
      ].map(([label, days]) => (
        <Button
          size="small"
          key={label}
          disabled={locked}
          onClick={() => choose(scheduleAddDays(today, Number(days)) ?? today)}
        >
          {t(String(label))}
        </Button>
      ))}
    </div>
  );
}
