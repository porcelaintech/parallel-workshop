cask "parallel-workbench" do
  version "0.4.1"
  sha256 :no_check

  # GitHub 仓库：porcelaintech/parallel-workshop
  url "https://github.com/porcelaintech/parallel-workshop/releases/download/v#{version}/ParallelWorkbench-#{version}.dmg"
  name "平行工作台"
  name "Parallel Workbench"
  desc "多模型平行问答工作台：一次提问，多个 AI 平台并排回答"
  homepage "https://github.com/porcelaintech/parallel-workshop"

  app "ParallelWorkbench.app"
end
