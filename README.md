# My n8n Portfolio

Automation workflows I've built with [n8n](https://n8n.io). Each folder has the workflow file (import it straight into n8n) and a README explaining what it does, how it works and how to set it up.

## Workflows

| Workflow | What it does | Tools |
|---|---|---|
| [**Meta Ad Analyser**](./meta-ad-analyser) | Scrapes a brand's live ads from the Meta Ad Library, has Gemini watch and listen to the top video ads (hook / body / CTA), ranks them by performance signals + AI creative score, and exports an Excel sheet and a PDF-ready report. | Apify, Google Gemini, Code nodes |

## Using a workflow

1. Download the `.json` file from the workflow's folder.
2. In n8n, go to **Workflows → Import from file**.
3. Add your own credentials (each README lists them). No API keys are stored in these files.

---

Built by **Pashmeen Kaur**.
