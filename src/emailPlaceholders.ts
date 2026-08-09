import type { QuoteRequest } from "./types";

export interface PlaceholderEmail {
  to: string;
  subject: string;
  body: string;
}

export function buildRfqLinkEmail(to: string, rfqLink: string): PlaceholderEmail {
  return {
    to,
    subject: "Time Trucking transport RFQ",
    body: `Please complete your secure Time Trucking RFQ here: ${rfqLink}`
  };
}

export function buildAdminSubmittedEmail(request: QuoteRequest): PlaceholderEmail {
  return {
    to: "admin@timetrucking.co.za",
    subject: `New RFQ submitted - ${request.companyName}`,
    body: `${request.companyName} submitted a quote request from ${request.collectionAddress} to ${request.deliveryAddress}.`
  };
}

export function buildClientQuoteEmail(request: QuoteRequest, quoteLink: string): PlaceholderEmail {
  return {
    to: request.email,
    subject: `Time Trucking quote for ${request.companyName}`,
    body: `Your quote is ready. View and respond here: ${quoteLink}`
  };
}

export function buildAdminDecisionEmail(request: QuoteRequest): PlaceholderEmail {
  return {
    to: "admin@timetrucking.co.za",
    subject: `Quote response - ${request.companyName}`,
    body: `${request.companyName} status is now ${request.status}.`
  };
}

