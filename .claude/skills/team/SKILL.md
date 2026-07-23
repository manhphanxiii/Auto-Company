---
name: team
description: "Quickly assemble a temporary AI agent team for a task. Automatically selects the most suitable members from .claude/agents/."
argument-hint: "[task description]"
disable-model-invocation: true
---

# Assemble a Temporary Team

Based on the task below, pick the most suitable members from the company's existing AI agents and assemble a temporary team to collaborate on it.

## Task

$ARGUMENTS

## Available Agents

Below are all of the company's agents, defined under the `.claude/agents/` directory:

| Agent | File | Function |
|-------|------|----------|
| CEO | `ceo-bezos` | Strategic decisions, business model, PR/FAQ, prioritization |
| CTO | `cto-vogels` | Technical architecture, technology selection, system design |
| Inversion/Critic | `critic-munger` | Challenge decisions, identify fatal flaws, pre-mortem, prevent groupthink |
| Product Design | `product-norman` | Product definition, user experience, usability |
| UI Design | `ui-duarte` | Visual design, design system, color and typography |
| Interaction Design | `interaction-cooper` | User flow, personas, interaction patterns |
| Full-Stack Dev | `fullstack-dhh` | Code implementation, technical approach, development |
| QA | `qa-bach` | Test strategy, quality control, bug analysis |
| DevOps/SRE | `devops-hightower` | Deployment pipelines, CI/CD, infrastructure, monitoring/ops |
| Marketing | `marketing-godin` | Positioning, brand, acquisition, content |
| Operations | `operations-pg` | User operations, growth, community, PMF |
| Sales | `sales-ross` | Sales funnel, conversion strategy |
| CFO | `cfo-campbell` | Pricing strategy, financial model, cost control, unit economics |
| Research | `research-thompson` | Market research, competitor analysis, industry trends, opportunity discovery |

## Execution Steps

### 1. Analyze the task and select members

Based on the nature of the task, select 2-5 of the most relevant agents as team members. Selection principles:
- **Only select what's necessary**: more people isn't better — match precisely to the task's needs
- **Consider the collaboration chain**: if the task spans design to development, make sure the key roles across that chain are included
- **Avoid redundancy**: don't select agents with overlapping functions at the same time

Briefly explain to the founder who you selected and why, then start assembling immediately.

### 2. Assemble the Agent Team

Use the Agent Teams feature to assemble the temporary team:
- Create the team, naming team_name briefly based on the task (English, kebab-case)
- Create a concrete task for each member (TaskCreate), with enough context in the task description
- Spawn each teammate with the Task tool, using `subagent_type: general-purpose`, and inject the full content of the corresponding agent file into the prompt as its role definition
- When spawning each teammate, tell them via the prompt: their role definition, the task to complete, and that output documents should be stored under `docs/<role>/`

### 3. Coordinate and synthesize

- Act as team lead and coordinate each member's work
- Collect each member's output and synthesize it into a unified conclusion or proposal
- If there's disagreement, list each side's view for the founder to decide
- Clean up team resources once the work is done

## Notes

- All communication happens in English.
- Each member's output is stored under `docs/<role>/` per convention
- The team is temporary and disbands once the task is complete
- The founder is the final decision-maker — agents offer recommendations but don't replace the decision
