"use client";

import { DashboardLayout } from "@hira-vn/views/layout";
import { HiraIcon } from "@hira-vn/ui/components/common/hira-icon";
import { SearchCommand, SearchTrigger } from "@hira-vn/views/search";
import { StarterContentPrompt } from "@hira-vn/views/onboarding";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <DashboardLayout
      loadingIndicator={<HiraIcon className="size-6" />}
      searchSlot={<SearchTrigger />}
      extra={
        <>
          <SearchCommand />
          <StarterContentPrompt />
        </>
      }
    >
      {children}
    </DashboardLayout>
  );
}
