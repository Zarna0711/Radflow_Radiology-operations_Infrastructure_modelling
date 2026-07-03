%% =========================================================================
%  RadFlow: Radiology Workflow and PACS Optimization Analysis
%  Course:  HI 797 - Radiology Informatics
%
%  HOW TO RUN:
%    1. Place Data_Entry_2017.csv in the same folder as this script
%    2. Open MATLAB and navigate to that folder
%    3. Run:  RadFlow_Combined
%    4. Four figure PNG files + RadFlow_Final_Processed_Dataset.csv will be
%       saved in the same folder
%% =========================================================================

clc; clear; close all;
rng(42);   % reproducible random numbers

%% ── Color Palette ─────────────────────────────────────────────────────────
cBlue   = [0.145 0.388 0.922];
cTeal   = [0.059 0.620 0.459];
cPurple = [0.486 0.227 0.929];
cAmber  = [0.851 0.467 0.024];
cRed    = [0.863 0.149 0.149];
cGray   = [0.420 0.443 0.502];
cHot    = [0.937 0.267 0.267];
cWarm   = [0.961 0.620 0.043];
cCold   = [0.231 0.510 0.965];

fprintf('=== RadFlow Combined Analysis Starting ===\n');

%% =========================================================================
%  SECTION 1 — Load & Clean Data
%% =========================================================================
fprintf('Loading dataset...\n');

% The CSV header contains commas inside bracket groups, e.g.:
%   "OriginalImage[Width,Height]" and "OriginalImagePixelSpacing[x,y]"
% MATLAB treats those internal commas as extra column delimiters, producing
% 12 columns instead of 11. We therefore skip the broken header row and
% assign our own clean column names.
T = readtable('Data_Entry_2017.csv', ...
    'VariableNamingRule', 'preserve', ...
    'ReadVariableNames', false, ...
    'HeaderLines', 1);

allNames = {'Image_Index','Finding_Labels','Followup_Num','Patient_ID', ...
            'Patient_Age','Patient_Gender','View_Position', ...
            'Width','Height','Pixel_Spacing_x','Pixel_Spacing_y','Drop'};
T.Properties.VariableNames = allNames(1:width(T));

% Drop trailing empty column if present
if ismember('Drop', T.Properties.VariableNames)
    T.Drop = [];
end
fprintf('Raw rows loaded: %d\n', height(T));

%% ── Parse Age (stored as '058Y', '006M', '001D', etc.) ───────────────────
ageRaw = T.Patient_Age;
Age    = zeros(height(T), 1);
for i = 1:height(T)
    s      = strtrim(char(ageRaw(i)));
    num    = str2double(s(1:end-1));
    suffix = s(end);
    if suffix == 'Y'
        Age(i) = num;
    elseif suffix == 'M'
        Age(i) = max(1, floor(num/12));
    elseif suffix == 'D'
        Age(i) = 1;
    else
        Age(i) = NaN;
    end
end
T.Age = Age;

% Filter to plausible ages
valid = T.Age >= 1 & T.Age <= 100 & ~isnan(T.Age);
T     = T(valid, :);
fprintf('After age filtering: %d rows\n', height(T));

% ── Optional: subsample to 10,000 for faster prototyping ──────────────────
% Uncomment the next two lines to match the project_797 script behaviour.
% idx = randperm(height(T), 10000);
% T   = T(idx, :);

%% =========================================================================
%  SECTION 2 — Derived Columns
%% =========================================================================

% --- File size (MB) — 16-bit grayscale: Width × Height × 2 bytes ----------
T.File_Size_MB = (T.Width .* T.Height .* 2) / 1e6;

% --- Number of findings per study (pipe-separated labels) -----------------
nRows       = height(T);
numFindings = zeros(nRows, 1);
for i = 1:nRows
    parts          = strsplit(char(T.Finding_Labels(i)), '|');
    numFindings(i) = numel(parts);
end
T.Num_Findings = numFindings;

% --- Has-finding flag ------------------------------------------------------
T.Has_Finding = ~strcmp(T.Finding_Labels, 'No Finding');

% --- Primary finding label (first label before any '|') --------------------
T.Finding_Labels = string(T.Finding_Labels);
T.Primary_Label  = extractBefore(T.Finding_Labels, "|");
noBar            = T.Primary_Label == "";
T.Primary_Label(noBar) = T.Finding_Labels(noBar);

%% =========================================================================
%  SECTION 3 — Simulate Turnaround Times
%% =========================================================================
% Acquisition: PA views are faster than AP views
isPA    = strcmp(T.View_Position, 'PA');
acqTime = zeros(nRows, 1);
acqTime( isPA) = 5 + 1.2 * randn(sum( isPA), 1);
acqTime(~isPA) = 8 + 1.8 * randn(sum(~isPA), 1);
T.Acq_Time = acqTime;

% PACS upload: proportional to file size
T.Upload_Time = T.File_Size_MB .* (0.05 + (0.12-0.05)*rand(nRows,1));

% Interpretation: base + per-finding penalty + elderly bonus
elderlyBonus         = zeros(nRows, 1);
elderly              = T.Age > 65;
elderlyBonus(elderly)= 2 + 0.5*randn(sum(elderly), 1);
T.Interp_Time        = 8 + 2*randn(nRows,1) + ...
                       T.Num_Findings .* (3 + 0.8*randn(nRows,1)) + ...
                       elderlyBonus;

% Reporting
T.Report_Time = 4 + randn(nRows, 1);

% Total TAT (floor at 3 min)
T.Total_TAT = max(3, T.Acq_Time + T.Upload_Time + T.Interp_Time + T.Report_Time);

% ── Legacy delay columns (compatible with project_797 output) ─────────────
% These map the simulated sub-times to the acquisition/interpretation/
% reporting delay nomenclature used in the original project_797 script.
T.acquisition_delay    = T.Acq_Time + T.Upload_Time;   % scan → ready in PACS
T.interpretation_delay = T.Interp_Time;                 % PACS ready → read
T.reporting_delay      = T.Report_Time;                 % read → report signed
T.total_time           = T.Total_TAT;

%% =========================================================================
%  SECTION 4 — PACS Storage Tiers (Time-based + Criticality)
%% =========================================================================

% ── 4a: Study date / age (simulated from today) ───────────────────────────
base_time       = datetime('today');
T.scan_time     = base_time - days(randi([0 60], nRows, 1));
T.study_date    = T.scan_time;
T.age_days      = days(datetime('today') - T.study_date);

% ── 4b: Criticality flag --------------------------------------------------
criticalKeywords = {'Pneumothorax','Edema','Consolidation','Pneumonia'};
isCritical       = false(nRows, 1);
for k = 1:numel(criticalKeywords)
    isCritical = isCritical | contains(T.Finding_Labels, criticalKeywords{k});
end
T.Is_Critical = isCritical;

% ── 4c: HSM tier assignment (criticality + follow-up visits) ─────────────
%   Hot  — critical findings OR ≥ 10 follow-up visits (SSD)
%   Warm — non-critical, 3-9 follow-up visits          (HDD)
%   Cold — everything else                              (Archive/tape)
hsm = repmat({'Cold'}, nRows, 1);
hsm(T.Is_Critical | T.Followup_Num >= 10) = {'Hot'};
hsm(~T.Is_Critical & T.Followup_Num >= 3 & T.Followup_Num < 10) = {'Warm'};
T.HSM_Tier = hsm;

% Logical index vectors for convenience
isHot  = strcmp(T.HSM_Tier, 'Hot');
isWarm = strcmp(T.HSM_Tier, 'Warm');
isCold = strcmp(T.HSM_Tier, 'Cold');

% ── 4d: Storage type labels also as string column (project_797 style) ────
T.storage_type = strings(nRows, 1);
for i = 1:nRows
    if T.age_days(i) <= 30
        T.storage_type(i) = "Hot Storage";
    elseif T.age_days(i) <= 180
        T.storage_type(i) = "Warm Storage";
    else
        T.storage_type(i) = "Cold Storage";
    end
end

%% =========================================================================
%  SECTION 5 — Summary Statistics (Command Window)
%% =========================================================================
fprintf('\n========== RADFLOW SUMMARY STATISTICS ==========\n');
fprintf('Total studies analyzed:   %d\n', height(T));
fprintf('Unique patients:          %d\n', numel(unique(T.Patient_ID)));
fprintf('Total PACS volume:        %.2f TB\n', sum(T.File_Size_MB)/1e6);

isPA_v = strcmp(T.View_Position, 'PA');
fprintf('Avg TAT (PA view):        %.1f min\n', mean(T.Total_TAT( isPA_v)));
fprintf('Avg TAT (AP view):        %.1f min\n', mean(T.Total_TAT(~isPA_v)));
fprintf('Interpretation %% of TAT:  %.1f%%\n', ...
        mean(T.Interp_Time)/mean(T.Total_TAT)*100);

fprintf('\n--- Average Workflow Delays (minutes) ---\n');
fprintf('Acquisition Delay:        %.2f\n', mean(T.acquisition_delay));
fprintf('Interpretation Delay:     %.2f\n', mean(T.interpretation_delay));
fprintf('Reporting Delay:          %.2f\n', mean(T.reporting_delay));
fprintf('Primary bottleneck:       Interpretation stage\n');

% Top-10% slow cases
threshold  = prctile(T.total_time, 90);
slow_cases = T(T.total_time > threshold, :);
fprintf('\nTotal Slow Cases (Top 10%%): %d\n', height(slow_cases));

fprintf('\nHSM Tier Breakdown:\n');
tierNames  = {'Hot','Warm','Cold'};
tierColors = [cHot; cWarm; cCold];
tierMasks  = {isHot, isWarm, isCold};
for t = 1:3
    tf = tierMasks{t};
    fprintf('  %-5s: %6d studies (%5.1f%%)  |  %.2f TB\n', ...
        tierNames{t}, sum(tf), 100*sum(tf)/height(T), ...
        sum(T.File_Size_MB(tf))/1e6);
end
fprintf('=================================================\n\n');

% Disease-wise delay table
delay_by_disease = groupsummary(T, 'Primary_Label', 'mean', 'total_time');
fprintf('--- Disease-wise Delay (Top 5) ---\n');
disp(head(delay_by_disease, 5));

%% =========================================================================
%  FIGURE 1 — Workflow Overview Dashboard
%% =========================================================================
fig1 = figure('Name','Fig1 Workflow Dashboard', ...
              'Color','w', 'Position',[50 50 1600 950]);
sgtitle('RadFlow: Radiology Workflow Analysis Dashboard', ...
        'FontSize',16, 'FontWeight','bold');

%-- 1a: TAT distribution by view position
subplot(2,3,1); hold on;
tatPA = T.Total_TAT(strcmp(T.View_Position,'PA'));
tatAP = T.Total_TAT(strcmp(T.View_Position,'AP'));
edges = linspace(0, 80, 50);
histogram(tatPA, edges, 'FaceColor',cBlue,  'FaceAlpha',0.65, 'EdgeColor','none');
histogram(tatAP, edges, 'FaceColor',cAmber, 'FaceAlpha',0.65, 'EdgeColor','none');
xline(mean(tatPA),'--','Color',cBlue,  'LineWidth',1.5);
xline(mean(tatAP),'--','Color',cAmber, 'LineWidth',1.5);
lgd = legend({'PA','AP'}, 'Location','northeast');
title(lgd,'View Position');
title('Total Turnaround Time by View');
xlabel('Minutes'); ylabel('Number of Studies');
set(gca,'Box','off','Color',[0.98 0.98 0.98]);

%-- 1b: Avg time per workflow stage (horizontal bar)
subplot(2,3,2);
stages    = {'Acquisition','PACS Upload','Interpretation','Reporting'};
avgTimes  = [mean(T.Acq_Time), mean(T.Upload_Time), ...
             mean(T.Interp_Time), mean(T.Report_Time)];
stageColors = [cTeal; cBlue; cPurple; cAmber];
bh = barh(avgTimes, 0.5, 'FaceColor','flat');
bh.CData = stageColors;
set(gca,'YTickLabel',stages,'Box','off','Color',[0.98 0.98 0.98]);
for i = 1:4
    text(avgTimes(i)+0.1, i, sprintf('%.1f min', avgTimes(i)), ...
         'VerticalAlignment','middle', 'FontSize',9);
end
title('Avg Time per Workflow Stage'); xlabel('Minutes');

%-- 1c: Avg TAT by number of findings
subplot(2,3,3);
maxF         = max(T.Num_Findings);
findGroups   = 1:maxF;
meanTAT_byF  = arrayfun(@(f) mean(T.Total_TAT(T.Num_Findings==f)), findGroups);
bar(findGroups, meanTAT_byF, 'FaceColor',cPurple, 'EdgeColor','none', 'FaceAlpha',0.85);
title('Avg TAT by Number of Findings');
xlabel('Number of Findings per Study'); ylabel('Avg TAT (minutes)');
set(gca,'Box','off','Color',[0.98 0.98 0.98]);

%-- 1d: Avg TAT by age group
subplot(2,3,4);
ageBins    = [0 20 40 60 80 100];
ageLabels  = {'0-20','21-40','41-60','61-80','81+'};
meanTAT_age = zeros(1,5);
for k = 1:5
    mask           = T.Age > ageBins(k) & T.Age <= ageBins(k+1);
    meanTAT_age(k) = mean(T.Total_TAT(mask));
end
bar(1:5, meanTAT_age, 'FaceColor',cTeal, 'EdgeColor','none', 'FaceAlpha',0.85);
set(gca,'XTickLabel',ageLabels,'Box','off','Color',[0.98 0.98 0.98]);
title('Avg TAT by Patient Age Group');
xlabel('Age Group'); ylabel('Avg TAT (minutes)');

%-- 1e: Gender distribution pie
subplot(2,3,5);
nMale   = sum(strcmp(T.Patient_Gender,'M'));
nFemale = sum(strcmp(T.Patient_Gender,'F'));
pie([nMale nFemale], {'Male','Female'});
colormap(gca, [cBlue; cPurple]);
title('Study Volume by Gender');

%-- 1f: Top 10 finding labels
subplot(2,3,6);
allFindings = {};
for i = 1:height(T)
    parts       = strsplit(char(T.Finding_Labels(i)), '|');
    allFindings = [allFindings, parts]; %#ok<AGROW>
end
[findCounts, findNames] = groupcounts(allFindings');
[~, sidx]     = sort(findCounts,'descend');
top10names    = findNames(sidx(1:10));
top10counts   = findCounts(sidx(1:10));
barh(1:10, flip(top10counts), 'FaceColor',cRed, 'EdgeColor','none', 'FaceAlpha',0.8);
set(gca,'YTick',1:10,'YTickLabel',flip(top10names),'Box','off','Color',[0.98 0.98 0.98]);
title('Top 10 Finding Labels'); xlabel('Number of Studies');

saveFig(fig1, 'fig1_workflow_dashboard.png');
fprintf('Figure 1 saved.\n');

%% =========================================================================
%  FIGURE 2 — PACS Storage & HSM Analysis
%% =========================================================================
fig2 = figure('Name','Fig2 PACS HSM', ...
              'Color','w', 'Position',[50 50 1600 950]);
sgtitle('RadFlow: PACS Storage Utilization & HSM Tier Analysis', ...
        'FontSize',16, 'FontWeight','bold');

%-- 2a: HSM tier study count
subplot(2,3,1);
tierCounts = cellfun(@(m) sum(m), tierMasks);
bh = bar(1:3, tierCounts, 'FaceColor','flat', 'EdgeColor','none', 'FaceAlpha',0.9);
bh.CData = tierColors;
set(gca,'XTickLabel',tierNames,'Box','off','Color',[0.98 0.98 0.98]);
for i = 1:3
    text(i, tierCounts(i)+400, num2str(tierCounts(i),'%d'), ...
         'HorizontalAlignment','center','FontWeight','bold','FontSize',9);
end
title('HSM Tier Distribution'); ylabel('Number of Studies'); xlabel('Storage Tier');

%-- 2b: Storage volume per tier (TB)
subplot(2,3,2);
tierVol = cellfun(@(m) sum(T.File_Size_MB(m))/1e6, tierMasks);
bh = bar(1:3, tierVol, 'FaceColor','flat', 'EdgeColor','none', 'FaceAlpha',0.9);
bh.CData = tierColors;
set(gca,'XTickLabel',tierNames,'Box','off','Color',[0.98 0.98 0.98]);
for i = 1:3
    text(i, tierVol(i)+0.005, sprintf('%.2f TB', tierVol(i)), ...
         'HorizontalAlignment','center','FontWeight','bold','FontSize',9);
end
title('Storage Volume by HSM Tier'); ylabel('Storage (TB)'); xlabel('Storage Tier');

%-- 2c: File size distribution
subplot(2,3,3); hold on;
histogram(T.File_Size_MB, 50, 'FaceColor',cBlue, 'EdgeColor','none', 'FaceAlpha',0.8);
xline(mean(T.File_Size_MB),'--r','LineWidth',2, ...
      'Label',sprintf('Mean: %.1f MB', mean(T.File_Size_MB)));
title('Image File Size Distribution');
xlabel('Estimated File Size (MB)'); ylabel('Number of Images');
set(gca,'Box','off','Color',[0.98 0.98 0.98]);

%-- 2d: Cumulative storage growth
subplot(2,3,4);
[~, sidx2] = sort(T.Followup_Num);
cumGB      = cumsum(T.File_Size_MB(sidx2)) / 1024;
x          = 1:height(T);
plot(x, cumGB, 'Color',cTeal, 'LineWidth',1.5);
patch([x, fliplr(x)],[cumGB', zeros(1,height(T))], cTeal, ...
      'FaceAlpha',0.15,'EdgeColor','none');
title('Cumulative PACS Storage Growth');
xlabel('Studies (ordered by follow-up)'); ylabel('Cumulative Storage (GB)');
set(gca,'Box','off','Color',[0.98 0.98 0.98]);

%-- 2e: Follow-up frequency with tier threshold markers
subplot(2,3,5); hold on;
fupVals   = 0:30;
fupCounts = arrayfun(@(v) sum(T.Followup_Num==v), fupVals);
bar(fupVals, fupCounts, 'FaceColor',cPurple, 'EdgeColor','none', 'FaceAlpha',0.85);
xline(9.5, '--', 'Color',cHot,  'LineWidth',1.5, 'Label','Hot/Warm');
xline(2.5, '--', 'Color',cWarm, 'LineWidth',1.5, 'Label','Warm/Cold');
title('Follow-up Visit Frequency');
xlabel('Follow-up Number'); ylabel('Number of Studies');
set(gca,'Box','off','Color',[0.98 0.98 0.98]);

%-- 2f: % in Hot tier by finding type
subplot(2,3,6);
critList = {'Pneumothorax','Edema','Pneumonia','Consolidation', ...
            'Infiltration','Atelectasis','Effusion','No Finding'};
hotPcts  = zeros(numel(critList), 1);
for k = 1:numel(critList)
    mask = contains(T.Finding_Labels, critList{k});
    if sum(mask) > 0
        hotPcts(k) = 100 * sum(isHot & mask) / sum(mask);
    end
end
barColors2 = repmat(cBlue, numel(critList), 1);
barColors2(hotPcts > 20, :) = repmat(cHot, sum(hotPcts>20), 1);
bh = barh(1:numel(critList), flip(hotPcts), 'FaceColor','flat','EdgeColor','none','FaceAlpha',0.85);
bh.CData = flipud(barColors2);
set(gca,'YTick',1:numel(critList),'YTickLabel',flip(critList), ...
        'Box','off','Color',[0.98 0.98 0.98]);
xline(20,'--','Color',cGray,'LineWidth',1,'Alpha',0.5);
title('% Studies in Hot Tier by Finding'); xlabel('% in Hot Storage');

saveFig(fig2, 'fig2_pacs_hsm.png');
fprintf('Figure 2 saved.\n');

%% =========================================================================
%  FIGURE 3 — Bottleneck & Workload Analysis
%% =========================================================================
fig3 = figure('Name','Fig3 Bottleneck Workload', ...
              'Color','w', 'Position',[50 50 1300 1000]);
sgtitle('RadFlow: Bottleneck & Workload Distribution Analysis', ...
        'FontSize',16, 'FontWeight','bold');

%-- 3a: TAT stage contribution — stacked bar
subplot(2,2,1);
stageMeans    = [mean(T.Acq_Time), mean(T.Upload_Time), ...
                 mean(T.Interp_Time), mean(T.Report_Time)];
totalMean     = sum(stageMeans);
stagePcts     = stageMeans / totalMean * 100;
stageColorsMat= [cTeal; cBlue; cPurple; cAmber];
bh = barh(1, stagePcts, 'stacked', 'EdgeColor','none');
set(bh, {'FaceColor'}, num2cell(stageColorsMat, 2));
leftEdge = 0;
for s = 1:4
    text(leftEdge + stagePcts(s)/2, 1, sprintf('%d%%', round(stagePcts(s))), ...
         'HorizontalAlignment','center','Color','w','FontWeight','bold','FontSize',10);
    leftEdge = leftEdge + stagePcts(s);
end
xlim([0 100]); yticks([]);
stageLabels = arrayfun(@(k) sprintf('%s (%.1f%%)', stages{k}, stagePcts(k)), ...
                        1:4, 'UniformOutput', false);
legend(stageLabels, 'Location','southoutside','NumColumns',2,'FontSize',8);
title('TAT Stage Contribution (%)'); xlabel('Percentage of Total TAT');
set(gca,'Box','off','Color',[0.98 0.98 0.98]);

%-- 3b: TAT percentile distribution
subplot(2,2,2);
pctLevels = [50 75 90 95 99];
pctVals   = prctile(T.Total_TAT, pctLevels);
pctColors = [cTeal; cBlue; cAmber; cRed; cPurple];
pctLabels = {'50th','75th','90th','95th','99th'};
bh = bar(1:5, pctVals, 'FaceColor','flat','EdgeColor','none','FaceAlpha',0.85);
bh.CData = pctColors;
set(gca,'XTickLabel',pctLabels,'Box','off','Color',[0.98 0.98 0.98]);
for i = 1:5
    text(i, pctVals(i)+0.3, sprintf('%.1f min',pctVals(i)), ...
         'HorizontalAlignment','center','FontSize',9);
end
title('TAT Percentile Distribution');
xlabel('Percentile'); ylabel('TAT (minutes)');

%-- 3c: Workload by patient follow-up group
subplot(2,2,3);
ptBins   = [-1 0 4 9 200];
ptLabels = {'New (0)','Low (1-4)','Moderate (5-9)','High (10+)'};
ptColors = [cCold; cTeal; cWarm; cHot];
ptCounts = zeros(1,4);
for k = 1:4
    ptCounts(k) = sum(T.Followup_Num > ptBins(k) & T.Followup_Num <= ptBins(k+1));
end
bh = bar(1:4, ptCounts, 'FaceColor','flat','EdgeColor','none','FaceAlpha',0.9);
bh.CData = ptColors;
set(gca,'XTickLabel',ptLabels,'Box','off','Color',[0.98 0.98 0.98]);
for i = 1:4
    text(i, ptCounts(i)+300, num2str(ptCounts(i),'%d'), ...
         'HorizontalAlignment','center','FontSize',9,'FontWeight','bold');
end
title('Workload by Patient Visit Frequency');
xlabel('Patient Type (Follow-up Group)'); ylabel('Number of Studies');

%-- 3d: Avg interpretation time heatmap (Age × View)
subplot(2,2,4);
ageBins2   = [0 30 50 70 100];
ageLabels2 = {'<30','30-50','50-70','70+'};
views      = {'PA','AP'};
heatData   = zeros(4,2);
for r = 1:4
    for c = 1:2
        mask         = T.Age > ageBins2(r) & T.Age <= ageBins2(r+1) & ...
                       strcmp(T.View_Position, views{c});
        heatData(r,c)= mean(T.Interp_Time(mask));
    end
end
imagesc(heatData);
colormap(gca, hot(256)); colorbar('eastoutside');
set(gca,'XTick',1:2,'XTickLabel',views, ...
        'YTick',1:4,'YTickLabel',ageLabels2,'Box','off');
title('Avg Interpretation Time (min): Age × View');
xlabel('View Position'); ylabel('Age Group');
for r = 1:4
    for c = 1:2
        text(c, r, sprintf('%.1f', heatData(r,c)), ...
             'HorizontalAlignment','center','Color','w', ...
             'FontWeight','bold','FontSize',10);
    end
end

saveFig(fig3, 'fig3_bottleneck_workload.png');
fprintf('Figure 3 saved.\n');

%% =========================================================================
%  FIGURE 4 — HSM Recommendation Framework
%% =========================================================================
fig4 = figure('Name','Fig4 HSM Framework', ...
              'Color','w', 'Position',[50 50 1400 550]);
sgtitle('RadFlow: HSM Tier Recommendation Framework', ...
        'FontSize',16, 'FontWeight','bold');

%-- 4a: Avg TAT by storage tier
subplot(1,3,1);
tierTAT = cellfun(@(m) mean(T.Total_TAT(m)), tierMasks);
bh = bar(1:3, tierTAT, 'FaceColor','flat','EdgeColor','none','FaceAlpha',0.9);
bh.CData = tierColors;
set(gca,'XTickLabel',tierNames,'Box','off','Color',[0.98 0.98 0.98]);
for i = 1:3
    text(i, tierTAT(i)+0.1, sprintf('%.1f min', tierTAT(i)), ...
         'HorizontalAlignment','center','FontWeight','bold','FontSize',10);
end
title('Avg TAT by Storage Tier');
ylabel('Avg TAT (minutes)'); xlabel('HSM Tier');

%-- 4b: Avg file size by tier
subplot(1,3,2);
tierSize = cellfun(@(m) mean(T.File_Size_MB(m)), tierMasks);
bh = bar(1:3, tierSize, 'FaceColor','flat','EdgeColor','none','FaceAlpha',0.9);
bh.CData = tierColors;
set(gca,'XTickLabel',tierNames,'Box','off','Color',[0.98 0.98 0.98]);
for i = 1:3
    text(i, tierSize(i)+0.1, sprintf('%.1f MB', tierSize(i)), ...
         'HorizontalAlignment','center','FontWeight','bold','FontSize',10);
end
title('Avg Image Size by Tier');
ylabel('Avg File Size (MB)'); xlabel('HSM Tier');

%-- 4c: Estimated monthly storage cost model
subplot(1,3,3);
costPerTB   = [230, 80, 20];    % SSD / HDD / Archive  $/TB/month
monthlyCost = tierVol .* costPerTB;
bh = bar(1:3, monthlyCost, 'FaceColor','flat','EdgeColor','none','FaceAlpha',0.9);
bh.CData = tierColors;
set(gca,'XTickLabel',tierNames,'Box','off','Color',[0.98 0.98 0.98]);
for i = 1:3
    text(i, monthlyCost(i)+1, sprintf('$%s', num2sepstr(monthlyCost(i))), ...
         'HorizontalAlignment','center','FontWeight','bold','FontSize',10);
end
title({'Estimated Monthly Storage Cost','(Illustrative \$/TB/month model)'});
ylabel('Estimated Monthly Cost (USD)'); xlabel('HSM Tier');

annotation('textbox',[0.1 0.01 0.8 0.06], ...
    'String', 'Hot = SSD (~$230/TB/mo)     Warm = HDD (~$80/TB/mo)     Cold = Archive (~$20/TB/mo)', ...
    'EdgeColor','none','HorizontalAlignment','center','FontSize',10);

saveFig(fig4, 'fig4_hsm_framework.png');
fprintf('Figure 4 saved.\n');

%% =========================================================================
%  SECTION 6 — Export Final Dataset
%% =========================================================================
writetable(T, 'RadFlow_Final_Processed_Dataset.csv');
fprintf('\nFinal dataset saved: RadFlow_Final_Processed_Dataset.csv\n');

fprintf('\n===== FINAL RADFLOW RESULTS =====\n');
fprintf('Total Records:              %d\n', height(T));
fprintf('Total Slow Cases (Top 10%%): %d\n', height(slow_cases));
fprintf('\n--- Average Workflow Delays (minutes) ---\n');
fprintf('Acquisition Delay:          %.2f\n', mean(T.acquisition_delay));
fprintf('Interpretation Delay:       %.2f\n', mean(T.interpretation_delay));
fprintf('Reporting Delay:            %.2f\n', mean(T.reporting_delay));
fprintf('\n=== All done! Check your folder for 4 PNG files + CSV. ===\n');

%% =========================================================================
%  LOCAL HELPER FUNCTIONS
%% =========================================================================

function saveFig(fig, filename)
%SAVEFIG  Save figure as high-resolution PNG
    exportgraphics(fig, filename, 'Resolution',150);
end

function s = num2sepstr(n)
%NUM2SEPSTR  Format a number with comma thousands separators, e.g. 1234 → '1,234'
    s = num2str(round(n));
    k = length(s) - 3;
    while k > 0
        s = [s(1:k) ',' s(k+1:end)];
        k = k - 3;
    end
end
