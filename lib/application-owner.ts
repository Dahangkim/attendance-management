export const applicationOwner = {
  name: process.env.NEXT_PUBLIC_APP_OWNER_NAME?.trim() || "김수현",
  maintainerEmail: process.env.NEXT_PUBLIC_MAINTAINER_EMAIL?.trim() || process.env.NEXT_PUBLIC_SUPPORT_EMAIL?.trim() || "indigoblau1223@gmail.com",
};
